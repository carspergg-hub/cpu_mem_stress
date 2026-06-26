#!/bin/bash
# =============================================================================
# CPU + Memory 压力测试脚本 (V7.3.2 NUMA bitmap 修复版)
# 修复：
#   ❌ 修复 NUMA online 输出 0-1 / 0-3 range 未解析问题
#   ✔ 支持 bitmap / range / list 混合格式
# =============================================================================

if [[ $# -lt 7 ]]; then
    echo "Usage: $0 <start_delay_max> <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]"
    exit 1
fi

START_DELAY_MAX=$1
CPU_MIN=$2
CPU_MAX=$3
CPU_WAVE_SEC=$4
MEM_MIN=$5
MEM_MAX=$6
MEM_WAVE_SEC=$7
DURATION=${8:-infinite}

if ! [[ "$START_DELAY_MAX" =~ ^[0-9]+$ ]]; then
    echo "Error: <start_delay_max> must be a non-negative integer."
    exit 1
fi

CPU_STATE_FILE="/dev/shm/cpu_p_$$"
MEM_STATE_FILE="/dev/shm/mem_p_$$"

# =============================================================================
# cleanup
# =============================================================================
cleanup() {
    trap '' SIGINT SIGTERM EXIT
    kill -TERM -$$ 2>/dev/null || kill 0 2>/dev/null
    wait 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# =============================================================================
# NUMA bitmap parser（核心修复）
# =============================================================================
expand_nodes() {
    local input=$1
    local out=""

    # 支持：0-1, 0,1, 0-3,8-10 混合
    IFS=',' read -ra parts <<< "$input"

    for p in "${parts[@]}"; do
        if [[ "$p" == *-* ]]; then
            start=${p%-*}
            end=${p#*-}

            # 防御非法输入
            [[ -z "$start" || -z "$end" ]] && continue

            for ((i=start;i<=end;i++)); do
                out="$out $i"
            done
        else
            out="$out $p"
        fi
    done

    echo "$out"
}

# =============================================================================
# value controller
# =============================================================================
value_controller() {
    local min=$1 max=$2 step=$3 file=$4
    local start=$SECONDS

    while [[ "$DURATION" == "infinite" ]] || (( SECONDS < start + DURATION )); do
        val=$min
        (( max > min )) && val=$(( RANDOM % (max - min + 1) + min ))
        echo "$val" > "$file"
        sleep "$step"
    done
}

# =============================================================================
# memory worker（保持你原模型）
# =============================================================================
memory_worker() {
exec python3 - "$1" "$2" "$3" <<'PY'
import time, sys, signal

node_id, state_file, duration = sys.argv[1:]

running = True
def stop(*_):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

file_path = "/proc/meminfo" if node_id == "global" else f"/sys/devices/system/node/node{node_id}/meminfo"

def parse(line):
    for x in reversed(line.split()):
        if x.isdigit():
            return int(x)
    return 0

def key_of(line):
    if ":" not in line:
        return ""
    return line.split(":", 1)[0].split()[-1]

def get_mem():
    fields = {}
    with open(file_path) as f:
        for line in f:
            fields[key_of(line)] = parse(line)

    total = fields.get("MemTotal", 0)
    if node_id == "global":
        available = fields.get(
            "MemAvailable",
            fields.get("MemFree", 0) + fields.get("Cached", 0) + fields.get("SReclaimable", 0),
        )
    else:
        available = (
            fields.get("MemFree", 0)
            + fields.get("FilePages", 0)
            + fields.get("SReclaimable", 0)
        )

    used = max(0, total - min(available, total))
    return total, used

total, _ = get_mem()
SAFE_FREE = max(int(total * 0.03), 1024 * 1024)

pool = []
start = time.time()
end = float("inf") if duration == "infinite" else start + int(duration)

penalty = 0

while running and time.time() < end:
    try:
        target_pct = int(open(state_file).read().strip())
    except:
        target_pct = 0

    target_pct = max(0, target_pct - penalty)

    target = min(total * target_pct / 100.0, total - SAFE_FREE)

    used = get_mem()[1]

    if used < target:
        try:
            pool.append(bytearray(50 * 1024 * 1024))
            penalty = max(0, penalty - 1)
        except MemoryError:
            penalty += 5
            time.sleep(5)

    elif used > target + 50 * 1024 and pool:
        pool.pop()

    time.sleep(0.3)

while pool:
    pool.pop()
    time.sleep(0.01)
PY
}

# =============================================================================
# CPU worker（PSI简化版）
# =============================================================================
run_on_cpu() {
    taskset -c "$1" bash -c '
STATE=$1; MIN=$2; DURATION=$3

psi() {
    [[ -f /proc/pressure/cpu ]] && awk "/some/ {print \$2}" /proc/pressure/cpu | cut -d= -f2 | cut -d. -f1 || echo 0
}

calibrate() {
    local n=5000 s e
    s=$(date +%s%N)
    for ((i=0;i<n;i++)); do ((x=i*i)); done
    e=$(date +%s%N)
    echo $(( n / ((e-s)/1000000 + 1) ))
}

L=$(calibrate)
start=$SECONDS

while [[ "$DURATION" == "infinite" ]] || (( SECONDS < start + DURATION )); do
    p=$(psi)
    (( p > 100 )) && p=100

    read -r v < "$STATE"
    v=${v%% *}
    [[ "$v" =~ ^[0-9]+$ ]] || v=$MIN

    p=$(( v + p/10 ))
    (( p > 100 )) && p=100

    burn=$(( p * L * 10 ))

    for ((i=0;i<burn;i++)); do ((x=i*i)); done

    idle=$((100 - p))
    (( idle > 0 )) && sleep "0.$idle"
done' _ "$CPU_STATE_FILE" "$CPU_MIN" "$DURATION" &
}

# =============================================================================
# start
# =============================================================================
if (( START_DELAY_MAX > 0 )); then
    START_DELAY=$(( RANDOM % (START_DELAY_MAX + 1) ))
    echo "[START_DELAY] sleep ${START_DELAY}s (range: 0-${START_DELAY_MAX}s)"
    sleep "$START_DELAY"
fi

printf "%-3s\n" "$CPU_MIN" > "$CPU_STATE_FILE"
printf "%-3s\n" "$MEM_MIN" > "$MEM_STATE_FILE"

value_controller "$CPU_MIN" "$CPU_MAX" "$CPU_WAVE_SEC" "$CPU_STATE_FILE" &
value_controller "$MEM_MIN" "$MEM_MAX" "$MEM_WAVE_SEC" "$MEM_STATE_FILE" &

# =============================================================================
# NUMA FIX (核心修复点)
# =============================================================================
if command -v numactl >/dev/null 2>&1; then

    NODE_RAW=$(cat /sys/devices/system/node/online 2>/dev/null)
    [[ -z "$NODE_RAW" ]] && NODE_RAW="0"

    for n in $(expand_nodes "$NODE_RAW"); do

        # 防御非法 node
        if [[ -d /sys/devices/system/node/node$n ]]; then

            echo "[NUMA] node=$n"

            numactl --preferred="$n" \
            bash -c "$(declare -f memory_worker); memory_worker '$n' '$MEM_STATE_FILE' '$DURATION'" &

        else
            echo "[WARN] skip invalid NUMA node $n"
        fi

    done

else
    memory_worker "global" "$MEM_STATE_FILE" "$DURATION" &
fi

# CPU workers
for c in $(seq 1 $(( $(nproc) - 1 ))); do
    run_on_cpu "$c"
done

wait
