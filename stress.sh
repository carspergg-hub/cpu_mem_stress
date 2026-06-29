#!/bin/bash
# =============================================================================
# CPU + Memory 压力测试脚本
# CPU 目标语义：
#   <cpu_min> <cpu_max> 表示加压后当前进程允许 CPU 集合的总使用率目标区间。
#   裸机无限制时等价于整机总 CPU；容器/cpuset 场景下只统计 Cpus_allowed_list 内的 CPU。
#   如果原有负载已经高于 cpu_max，脚本只能把自身 CPU 压力降到 0，不能降低其他进程的 CPU 使用率。
# 内存目标语义：
#   <mem_min> <mem_max> 表示加压后系统/NUMA 节点的估算已用内存目标区间。
#   如果原有内存占用已经高于 mem_max，脚本只能释放自己申请的内存。
# =============================================================================

if [[ $# -lt 6 ]]; then
    echo "Usage: $0 <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]"
    exit 1
fi

CPU_MIN=$1
CPU_MAX=$2
CPU_CHANGE_SEC=$3
MEM_MIN=$4
MEM_MAX=$5
MEM_CHANGE_SEC=$6
DURATION=${7:-infinite}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_percent() {
    local name=$1 value=$2
    is_uint "$value" || die "$name must be an integer between 0 and 100"
    (( value >= 0 && value <= 100 )) || die "$name must be between 0 and 100"
}

validate_positive_int() {
    local name=$1 value=$2
    is_uint "$value" || die "$name must be a positive integer"
    (( value > 0 )) || die "$name must be greater than 0"
}

require_cmd() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

validate_percent "cpu_min" "$CPU_MIN"
validate_percent "cpu_max" "$CPU_MAX"
validate_percent "mem_min" "$MEM_MIN"
validate_percent "mem_max" "$MEM_MAX"
(( CPU_MIN <= CPU_MAX )) || die "cpu_min must be <= cpu_max"
(( MEM_MIN <= MEM_MAX )) || die "mem_min must be <= mem_max"
validate_positive_int "cpu_step" "$CPU_CHANGE_SEC"
validate_positive_int "mem_step" "$MEM_CHANGE_SEC"
if [[ "$DURATION" != "infinite" ]]; then
    validate_positive_int "duration" "$DURATION"
fi

[[ -r /proc/stat ]] || die "/proc/stat is required; this script must run on Linux with procfs"
for cmd in taskset python3 nproc date; do
    require_cmd "$cmd"
done
[[ "$(date +%s%N)" =~ ^[0-9]+$ ]] || die "GNU date with %N support is required"
CPU_COUNT=$(nproc)
is_uint "$CPU_COUNT" && (( CPU_COUNT > 0 )) || die "nproc returned an invalid CPU count: $CPU_COUNT"

STATE_DIR=${STRESS_STATE_DIR:-/dev/shm}
if [[ ! -d "$STATE_DIR" || ! -w "$STATE_DIR" ]]; then
    STATE_DIR=/tmp
fi
[[ -d "$STATE_DIR" && -w "$STATE_DIR" ]] || die "no writable state directory found"

CPU_STATE_FILE="$STATE_DIR/cpu_p_$$"
MEM_STATE_FILE="$STATE_DIR/mem_p_$$"
CHILD_PIDS=()

# =============================================================================
# cleanup
# =============================================================================
cleanup() {
    local exit_code=$?
    local pid

    trap - SIGINT SIGTERM EXIT

    for pid in "${CHILD_PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    wait 2>/dev/null || true
    rm -f "$CPU_STATE_FILE" "$MEM_STATE_FILE"
    exit "$exit_code"
}
trap cleanup SIGINT SIGTERM EXIT

# =============================================================================
# NUMA bitmap parser
# =============================================================================
expand_nodes() {
    local input=$1
    local out=""
    local p start end i

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

get_allowed_cpus() {
    local key value raw=""

    while read -r key value; do
        if [[ "$key" == "Cpus_allowed_list:" ]]; then
            raw=$value
            break
        fi
    done < /proc/self/status

    [[ -n "$raw" ]] || raw="0-$(( CPU_COUNT - 1 ))"
    expand_nodes "$raw"
}

within_duration() {
    local start=$1
    [[ "$DURATION" == "infinite" ]] || (( SECONDS < start + DURATION ))
}

sleep_with_deadline() {
    local seconds=$1 start=$2
    local end=$(( SECONDS + seconds ))
    local deadline remain

    if [[ "$DURATION" != "infinite" ]]; then
        deadline=$(( start + DURATION ))
        (( end > deadline )) && end=$deadline
    fi

    while (( SECONDS < end )); do
        remain=$(( end - SECONDS ))
        (( remain < 1 )) && break
        (( remain > 1 )) && sleep 1 || sleep "$remain"
    done
}

# =============================================================================
# random target controller
# =============================================================================
random_value_controller() {
    local min=$1 max=$2 step=$3 file=$4
    local start=$SECONDS

    while within_duration "$start"; do
        val=$min
        (( max > min )) && val=$(( RANDOM % (max - min + 1) + min ))
        echo "$val" > "$file"
        sleep_with_deadline "$step" "$start"
    done
}

# =============================================================================
# total CPU controller
# =============================================================================
read_cpu_stat() {
    local allowed_pattern=" $1 "
    local total_idle=0 total_total=0
    local cpu user nice system idle iowait irq softirq steal rest core_id
    local idle_all non_idle

    while read -r cpu user nice system idle iowait irq softirq steal rest; do
        [[ "$cpu" =~ ^cpu([0-9]+)$ ]] || continue
        core_id="${BASH_REMATCH[1]}"
        [[ "$allowed_pattern" == *" $core_id "* ]] || continue

        idle_all=$(( idle + iowait ))
        non_idle=$(( user + nice + system + irq + softirq + steal ))
        total_idle=$(( total_idle + idle_all ))
        total_total=$(( total_total + idle_all + non_idle ))
    done < /proc/stat

    echo "$total_total $total_idle"
}

cpu_total_usage() {
    local interval=${1:-1}
    local allowed_cpus=$2
    local total1 idle1 total2 idle2 total_delta idle_delta used_delta

    read -r total1 idle1 < <(read_cpu_stat "$allowed_cpus")
    sleep "$interval"
    read -r total2 idle2 < <(read_cpu_stat "$allowed_cpus")

    total_delta=$(( total2 - total1 ))
    idle_delta=$(( idle2 - idle1 ))

    if (( total_delta <= 0 )); then
        echo 0
        return
    fi

    used_delta=$(( total_delta - idle_delta ))
    echo $(( (100 * used_delta + total_delta / 2) / total_delta ))
}

cpu_total_controller() {
    local min=$1 max=$2 change_sec=$3 file=$4 allowed_cpus=$5
    local start=$SECONDS
    local next_change=$SECONDS
    local target=$min
    local load=0
    local actual error adjust

    printf "%-3s\n" "$load" > "$file"

    while within_duration "$start"; do
        if (( SECONDS >= next_change )); then
            target=$min
            (( max > min )) && target=$(( RANDOM % (max - min + 1) + min ))
            next_change=$(( SECONDS + change_sec ))
        fi

        actual=$(cpu_total_usage 0.5 "$allowed_cpus")

        read -r load < "$file"
        load=${load%% *}
        [[ "$load" =~ ^[0-9]+$ ]] || load=0

        # 比例控制：死区 +/-2%，限幅 +/-15，避免大误差时一次性跳变导致振荡。
        error=$(( target - actual ))
        if (( error > 2 )); then
            adjust=$(( error / 3 ))
            (( adjust < 1 )) && adjust=1
            (( adjust > 15 )) && adjust=15
        elif (( error < -2 )); then
            adjust=$(( error / 3 ))
            (( adjust > -1 )) && adjust=-1
            (( adjust < -15 )) && adjust=-15
        else
            adjust=0
        fi

        load=$(( load + adjust ))
        (( load < 0 )) && load=0
        (( load > 100 )) && load=100

        printf "%-3s\n" "$load" > "$file"
    done
}

# =============================================================================
# memory worker
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

def meminfo_key(line):
    return line.split(":", 1)[0].split()[-1].strip()

def get_mem():
    values = {}

    with open(file_path) as f:
        for line in f:
            if ":" in line:
                values[meminfo_key(line)] = parse(line)

    total = values.get("MemTotal", 0)
    if total <= 0:
        return 0, 0

    if "MemAvailable" in values:
        used = total - values["MemAvailable"]
    else:
        free = values.get("MemFree", 0)
        file_pages = values.get("FilePages", values.get("Cached", 0))
        reclaimable = values.get("SReclaimable", 0)
        used = total - free - file_pages - reclaimable

        if used < 0:
            used = values.get("AnonPages", 0) + values.get("SUnreclaim", 0)

    used = max(0, min(used, total))
    return total, used

total, _ = get_mem()
SAFE_FREE = max(int(total * 0.03), 1024 * 1024)

pool = []
start = time.time()
end = float("inf") if duration == "infinite" else start + int(duration)

penalty = 0

while running and time.time() < end:
    try:
        with open(state_file) as f:
            target_pct = int(f.read().strip())
    except (OSError, ValueError):
        target_pct = 0

    target_pct = max(0, min(100, target_pct - penalty))

    target = max(0, min(total * target_pct / 100.0, total - SAFE_FREE))

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
# CPU worker
# =============================================================================
run_on_cpu() {
    taskset -c "$1" bash -c '
STATE=$1
DURATION=$2
start=$SECONDS

calibrate() {
    local n=5000 s e elapsed
    s=$(date +%s%N)
    for ((i=0;i<n;i++)); do ((x=i*i)); done
    e=$(date +%s%N)
    elapsed=$(( (e - s) / 1000000 + 1 ))
    echo $(( n / elapsed ))
}

L=$(calibrate)
next_calibrate=$(( SECONDS + 30 ))

while [[ "$DURATION" == "infinite" ]] || (( SECONDS < start + DURATION )); do
    if (( SECONDS >= next_calibrate )); then
        L=$(calibrate)
        next_calibrate=$(( SECONDS + 30 ))
    fi

    read -r v < "$STATE"
    v=${v%% *}
    [[ "$v" =~ ^[0-9]+$ ]] || v=0

    (( v < 0 )) && v=0
    (( v > 100 )) && v=100

    burn=$(( v * L ))
    for ((i=0;i<burn;i++)); do ((x=i*i)); done

    idle_ms=$((100 - v))
    if (( idle_ms > 0 )); then
        printf -v idle_s "0.%03d" "$idle_ms"
        sleep "$idle_s"
    fi
done' _ "$CPU_STATE_FILE" "$DURATION" &
    CHILD_PIDS+=("$!")
}

# =============================================================================
# start
# =============================================================================
printf "%-3s\n" "0" > "$CPU_STATE_FILE"
printf "%-3s\n" "$MEM_MIN" > "$MEM_STATE_FILE"

read -ra CPU_ARRAY <<< "$(get_allowed_cpus)"
(( ${#CPU_ARRAY[@]} > 0 )) || die "no allowed CPUs found"
ALLOWED_CPUS="${CPU_ARRAY[*]}"

cpu_total_controller "$CPU_MIN" "$CPU_MAX" "$CPU_CHANGE_SEC" "$CPU_STATE_FILE" "$ALLOWED_CPUS" &
CHILD_PIDS+=("$!")
random_value_controller "$MEM_MIN" "$MEM_MAX" "$MEM_CHANGE_SEC" "$MEM_STATE_FILE" &
CHILD_PIDS+=("$!")

# =============================================================================
# NUMA
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
            CHILD_PIDS+=("$!")

        else
            echo "[WARN] skip invalid NUMA node $n"
        fi

    done

else
    memory_worker "global" "$MEM_STATE_FILE" "$DURATION" &
    CHILD_PIDS+=("$!")
fi

# CPU workers
for c in "${CPU_ARRAY[@]}"; do
    run_on_cpu "$c"
done

wait
