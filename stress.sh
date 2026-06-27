#!/bin/bash
# =============================================================================
# CPU + Memory 压力测试脚本 (V7.3.2 NUMA bitmap 修复版)
# 修复：
#   ❌ 修复 NUMA online 输出 0-1 / 0-3 range 未解析问题
#   ✔ 支持 bitmap / range / list 混合格式
# =============================================================================

if [[ $# -lt 8 ]]; then
    echo "Usage: $0 <start_delay_max> <end_delay_max> <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]"
    exit 1
fi

START_DELAY_MAX=$1
END_DELAY_MAX=$2
CPU_MIN=$3
CPU_MAX=$4
CPU_WAVE_SEC=$5
MEM_MIN=$6
MEM_MAX=$7
MEM_WAVE_SEC=$8
DURATION=${9:-infinite}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_percent() {
    is_non_negative_integer "$1" && (( 10#$1 <= 100 ))
}

if ! is_non_negative_integer "$START_DELAY_MAX"; then
    echo "Error: <start_delay_max> must be a non-negative integer."
    exit 1
fi

if ! is_non_negative_integer "$END_DELAY_MAX"; then
    echo "Error: <end_delay_max> must be a non-negative integer."
    exit 1
fi

if ! is_percent "$CPU_MIN" || ! is_percent "$CPU_MAX"; then
    echo "Error: <cpu_min> and <cpu_max> must be integers in range 0-100."
    exit 1
fi

if (( 10#$CPU_MIN > 10#$CPU_MAX )); then
    echo "Error: <cpu_min> must be less than or equal to <cpu_max>."
    exit 1
fi

if ! is_positive_integer "$CPU_WAVE_SEC"; then
    echo "Error: <cpu_step> must be a positive integer."
    exit 1
fi

if ! is_percent "$MEM_MIN" || ! is_percent "$MEM_MAX"; then
    echo "Error: <mem_min> and <mem_max> must be integers in range 0-100."
    exit 1
fi

if (( 10#$MEM_MIN > 10#$MEM_MAX )); then
    echo "Error: <mem_min> must be less than or equal to <mem_max>."
    exit 1
fi

if ! is_positive_integer "$MEM_WAVE_SEC"; then
    echo "Error: <mem_step> must be a positive integer."
    exit 1
fi

if [[ "$DURATION" != "infinite" ]] && ! is_non_negative_integer "$DURATION"; then
    echo "Error: [duration] must be a non-negative integer or 'infinite'."
    exit 1
fi

START_DELAY_MAX=$((10#$START_DELAY_MAX))
END_DELAY_MAX=$((10#$END_DELAY_MAX))
CPU_MIN=$((10#$CPU_MIN))
CPU_MAX=$((10#$CPU_MAX))
CPU_WAVE_SEC=$((10#$CPU_WAVE_SEC))
MEM_MIN=$((10#$MEM_MIN))
MEM_MAX=$((10#$MEM_MAX))
MEM_WAVE_SEC=$((10#$MEM_WAVE_SEC))
if [[ "$DURATION" != "infinite" ]]; then
    DURATION=$((10#$DURATION))
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
    rm -f "$CPU_STATE_FILE" "$MEM_STATE_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# =============================================================================
# NUMA bitmap parser（核心修复）
# =============================================================================
expand_nodes() {
    local input=$1
    local out=""
    local start end i p
    local -a parts

    # 支持：0-1, 0,1, 0-3,8-10 混合
    IFS=',' read -ra parts <<< "$input"

    for p in "${parts[@]}"; do
        if [[ "$p" == *-* ]]; then
            start=${p%-*}
            end=${p#*-}

            if ! is_non_negative_integer "$start" || ! is_non_negative_integer "$end"; then
                echo "[WARN] skip invalid NUMA node range $p" >&2
                continue
            fi

            if (( 10#$start > 10#$end )); then
                echo "[WARN] skip invalid NUMA node range $p" >&2
                continue
            fi

            start=$((10#$start))
            end=$((10#$end))

            for ((i=start;i<=end;i++)); do
                out="$out $i"
            done
        else
            if is_non_negative_integer "$p"; then
                out="$out $((10#$p))"
            else
                echo "[WARN] skip invalid NUMA node $p" >&2
            fi
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
    local val

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
    local node_id=$1 state_file=$2 duration=$3 end_delay_max=$4 preferred_node=${5:-}
    local cmd=(python3 - "$node_id" "$state_file" "$duration" "$end_delay_max")

    if [[ -n "$preferred_node" ]]; then
        cmd=(numactl --preferred="$preferred_node" "${cmd[@]}")
    fi

    exec "${cmd[@]}" <<'PY'
import random, time, sys, signal

node_id, state_file, duration, end_delay_max = sys.argv[1:]

running = True
def stop(*_):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

file_path = "/proc/meminfo" if node_id == "global" else f"/sys/devices/system/node/node{node_id}/meminfo"
GLOBAL_MEMINFO = "/proc/meminfo"

def parse(line):
    for x in reversed(line.split()):
        if x.isdigit():
            return int(x)
    return 0

def key_of(line):
    if ":" not in line:
        return ""
    parts = line.split(":", 1)[0].split()
    return parts[-1] if parts else ""

def read_fields(path):
    fields = {}
    with open(path) as f:
        for line in f:
            fields[key_of(line)] = parse(line)
    return fields

def reclaimable(fields):
    return fields.get("KReclaimable", fields.get("SReclaimable", 0))

def get_mem():
    fields = read_fields(file_path)
    total = fields.get("MemTotal", 0)
    if node_id == "global":
        available = fields.get(
            "MemAvailable",
            fields.get("MemFree", 0) + fields.get("Cached", 0) + reclaimable(fields),
        )
    else:
        # FilePages can be dominated by tmpfs/shmem on NUMA nodes, so do not treat
        # it as safely reclaimable. Prefer a conservative per-node availability.
        available = fields.get("MemFree", 0) + reclaimable(fields)

    used = max(0, total - min(available, total))
    return total, used

def global_available():
    try:
        fields = read_fields(GLOBAL_MEMINFO)
    except OSError:
        return 0
    available = fields.get(
        "MemAvailable",
        fields.get("MemFree", 0) + fields.get("Cached", 0) + reclaimable(fields),
    )
    return max(0, available)

def duration_end(value):
    if value == "infinite":
        return float("inf")
    try:
        seconds = int(value)
    except ValueError:
        raise SystemExit(f"invalid duration: {value}")
    if seconds < 0:
        raise SystemExit(f"invalid duration: {value}")
    return time.time() + seconds

def parse_delay_max(value):
    try:
        delay_max = int(value)
    except ValueError:
        return 0
    return max(0, delay_max)

def random_delay(delay_max):
    if delay_max <= 0:
        return 0
    return random.randint(0, delay_max)

def sleep_until_release(delay):
    if delay <= 0:
        return
    print(f"[END_DELAY] node={node_id} sleep {delay}s before release", flush=True)
    deadline = time.time() + delay
    while running:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        time.sleep(min(1, remaining))

total, _ = get_mem()
SAFE_FREE_MIN_KB = 1024 * 1024  # Keep at least 1 GiB free to avoid host reclaim storms.
ALLOC_CHUNK_BYTES = 50 * 1024 * 1024
RELEASE_MARGIN_KB = 50 * 1024
SAFE_FREE = max(int(total * 0.03), SAFE_FREE_MIN_KB)
PENALTY_STEP = 5
print(f"[MEM_START] node={node_id} total_kb={total} safe_free_kb={SAFE_FREE}", flush=True)

pool = []
end = duration_end(duration)

penalty = 0
global_guard_logged = False

while running and time.time() < end:
    try:
        with open(state_file) as f:
            target_pct = int(f.read().strip())
    except (OSError, ValueError):
        target_pct = 0

    target_pct = max(0, target_pct - penalty)

    target = min(total * target_pct / 100.0, total - SAFE_FREE)

    used = get_mem()[1]
    allocated = False

    if used < target:
        available_global = global_available()
        if available_global < SAFE_FREE_MIN_KB:
            penalty += PENALTY_STEP
            if not global_guard_logged:
                print(
                    f"[MEM_GUARD] node={node_id} global_available_kb={available_global} "
                    f"below_safe_free_kb={SAFE_FREE_MIN_KB}; pause allocation",
                    flush=True,
                )
                global_guard_logged = True
            time.sleep(1)
        else:
            global_guard_logged = False
            try:
                pool.append(bytearray(ALLOC_CHUNK_BYTES))
                allocated = True
            except MemoryError:
                penalty += PENALTY_STEP
                time.sleep(5)

    elif used > target + RELEASE_MARGIN_KB and pool:
        pool.pop()

    if allocated:
        penalty = max(0, penalty - PENALTY_STEP)

    time.sleep(0.3)

if running:
    delay_max = parse_delay_max(end_delay_max)
    if delay_max > 0:
        sleep_until_release(random_delay(delay_max))

while pool:
    pool.pop()
    time.sleep(0.01)

print(f"[MEM_EXIT] node={node_id}", flush=True)
PY
}

# =============================================================================
# CPU worker（PSI简化版）
# =============================================================================
run_on_cpu() {
    taskset -c "$1" bash -c '
STATE=$1; MIN=$2; DURATION=$3; END_DELAY_MAX=$4; CPU_ID=$5

psi() {
    local label fields field value
    if [[ -r /proc/pressure/cpu ]]; then
        while read -r label fields; do
            if [[ "$label" == "some" ]]; then
                for field in $fields; do
                    case "$field" in
                        avg10=*)
                            value=${field#avg10=}
                            echo "${value%%.*}"
                            return
                            ;;
                    esac
                done
            fi
        done < /proc/pressure/cpu
    fi
    echo 0
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
    if (( idle >= 100 )); then
        sleep 1
    elif (( idle > 0 )); then
        printf -v idle_sec "0.%02d" "$idle"
        sleep "$idle_sec"
    fi
done

if [[ "$DURATION" != "infinite" ]] && (( END_DELAY_MAX > 0 )); then
    END_DELAY=$(( RANDOM % (END_DELAY_MAX + 1) ))
    if (( END_DELAY > 0 )); then
        echo "[END_DELAY] cpu=$CPU_ID sleep ${END_DELAY}s before exit"
        sleep "$END_DELAY"
    fi
fi' _ "$CPU_STATE_FILE" "$CPU_MIN" "$DURATION" "$END_DELAY_MAX" "$1" &
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

            memory_worker "$n" "$MEM_STATE_FILE" "$DURATION" "$END_DELAY_MAX" "$n" &

        else
            echo "[WARN] skip invalid NUMA node $n"
        fi

    done

else
    memory_worker "global" "$MEM_STATE_FILE" "$DURATION" "$END_DELAY_MAX" &
fi

# CPU workers
CPU_COUNT=$(nproc 2>/dev/null)
if ! is_positive_integer "$CPU_COUNT"; then
    echo "[WARN] failed to detect CPU count; skip CPU workers"
    CPU_COUNT=1
fi

if (( CPU_COUNT <= 1 )); then
    echo "[WARN] only one CPU detected; skip CPU workers to keep CPU0 reserved"
else
    for ((c=1; c<CPU_COUNT; c++)); do
        run_on_cpu "$c"
    done
fi

wait
