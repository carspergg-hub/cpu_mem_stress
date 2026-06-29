#!/bin/bash
# =============================================================================
# CPU + Memory 压力测试脚本
# CPU 目标语义：
#   <cpu_min> <cpu_max> 表示加压后当前进程允许 CPU 集合的总使用率目标区间。
#   裸机无限制时等价于整机总 CPU；如果进程被限制到部分 CPU，则只统计 Cpus_allowed_list 内的 CPU。
#   如果原有负载已经高于 cpu_max，脚本只能把自身 CPU 压力降到 0，不能降低其他进程的 CPU 使用率。
# 内存目标语义：
#   <mem_min> <mem_max> 表示加压后系统/NUMA 节点的估算已用内存目标区间。
#   如果原有内存占用已经高于 mem_max，脚本只能释放自己申请的内存。
# =============================================================================

if (( $# < 8 || $# > 9 )); then
    echo "Usage: $0 <start_delay_max> <end_delay_max> <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]"
    exit 1
fi

START_DELAY_MAX=$1
END_DELAY_MAX=$2
CPU_MIN=$3
CPU_MAX=$4
CPU_CHANGE_SEC=$5
MEM_MIN=$6
MEM_MAX=$7
MEM_CHANGE_SEC=$8
DURATION=${9:-infinite}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_percent() {
    is_non_negative_integer "$1" && (( 10#$1 <= 100 ))
}

require_cmd() {
    local cmd=$1
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

is_non_negative_integer "$START_DELAY_MAX" || die "start_delay_max must be a non-negative integer"
is_non_negative_integer "$END_DELAY_MAX" || die "end_delay_max must be a non-negative integer"
is_percent "$CPU_MIN" || die "cpu_min must be an integer between 0 and 100"
is_percent "$CPU_MAX" || die "cpu_max must be an integer between 0 and 100"
is_percent "$MEM_MIN" || die "mem_min must be an integer between 0 and 100"
is_percent "$MEM_MAX" || die "mem_max must be an integer between 0 and 100"
is_positive_integer "$CPU_CHANGE_SEC" || die "cpu_step must be a positive integer"
is_positive_integer "$MEM_CHANGE_SEC" || die "mem_step must be a positive integer"
if [[ "$DURATION" != "infinite" ]]; then
    is_positive_integer "$DURATION" || die "duration must be a positive integer or 'infinite'"
fi

START_DELAY_MAX=$((10#$START_DELAY_MAX))
END_DELAY_MAX=$((10#$END_DELAY_MAX))
CPU_MIN=$((10#$CPU_MIN))
CPU_MAX=$((10#$CPU_MAX))
CPU_CHANGE_SEC=$((10#$CPU_CHANGE_SEC))
MEM_MIN=$((10#$MEM_MIN))
MEM_MAX=$((10#$MEM_MAX))
MEM_CHANGE_SEC=$((10#$MEM_CHANGE_SEC))
if [[ "$DURATION" != "infinite" ]]; then
    DURATION=$((10#$DURATION))
fi

(( CPU_MIN <= CPU_MAX )) || die "cpu_min must be <= cpu_max"
(( MEM_MIN <= MEM_MAX )) || die "mem_min must be <= mem_max"

[[ -r /proc/stat ]] || die "/proc/stat is required; this script must run on Linux with procfs"
[[ -r /proc/self/status ]] || die "/proc/self/status is required; this script must run on Linux with procfs"
for cmd in taskset python3 nproc date; do
    require_cmd "$cmd"
done
[[ "$(date +%s%N)" =~ ^[0-9]+$ ]] || die "GNU date with %N support is required"
CPU_COUNT=$(nproc)
is_positive_integer "$CPU_COUNT" || die "nproc returned an invalid CPU count: $CPU_COUNT"

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
# bitmap / range parser
# =============================================================================
expand_nodes() {
    local input=$1
    local out=""
    local start end i p
    local -a parts

    IFS=',' read -ra parts <<< "$input"

    for p in "${parts[@]}"; do
        if [[ "$p" == *-* ]]; then
            start=${p%-*}
            end=${p#*-}

            if ! is_non_negative_integer "$start" || ! is_non_negative_integer "$end"; then
                echo "[WARN] skip invalid range $p" >&2
                continue
            fi

            start=$((10#$start))
            end=$((10#$end))
            if (( start > end )); then
                echo "[WARN] skip invalid range $p" >&2
                continue
            fi

            for ((i=start;i<=end;i++)); do
                out="$out $i"
            done
        else
            if is_non_negative_integer "$p"; then
                out="$out $((10#$p))"
            else
                echo "[WARN] skip invalid value $p" >&2
            fi
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

random_delay() {
    local delay_max=$1
    (( delay_max > 0 )) && echo $(( RANDOM % (delay_max + 1) )) || echo 0
}

# =============================================================================
# random target controller
# =============================================================================
random_value_controller() {
    local min=$1 max=$2 step=$3 file=$4
    local start=$SECONDS
    local val

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

        # Proportional controller with +/-2% deadband and +/-15 step cap.
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
            key = key_of(line)
            if key:
                fields[key] = parse(line)
    return fields

def reclaimable(fields):
    return fields.get("KReclaimable", fields.get("SReclaimable", 0))

def file_cache(fields):
    return max(0, fields.get("FilePages", 0) - fields.get("Shmem", 0))

def estimate_available(fields):
    if node_id == "global":
        return fields.get(
            "MemAvailable",
            fields.get("MemFree", 0) + fields.get("Cached", 0) + reclaimable(fields),
        )

    return fields.get("MemFree", 0) + file_cache(fields) + reclaimable(fields)

def get_mem():
    fields = read_fields(file_path)
    total = fields.get("MemTotal", 0)
    available = estimate_available(fields)
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

start_fields = read_fields(file_path)
total = start_fields.get("MemTotal", 0)
start_available = estimate_available(start_fields)
start_filepages = start_fields.get("FilePages", 0)
start_shmem = start_fields.get("Shmem", 0)
start_reclaimable = reclaimable(start_fields)
start_file_cache = file_cache(start_fields)
shmem_present = 1 if "Shmem" in start_fields else 0
SAFE_FREE_MIN_KB = 1024 * 1024
ALLOC_CHUNK_BYTES = 50 * 1024 * 1024
RELEASE_MARGIN_KB = 50 * 1024
SAFE_FREE = max(int(total * 0.03), SAFE_FREE_MIN_KB)
PENALTY_STEP = 5
print(
    f"[MEM_START] node={node_id} total_kb={total} available_kb={start_available} "
    f"safe_free_kb={SAFE_FREE} filepages_kb={start_filepages} shmem_kb={start_shmem} "
    f"shmem_present={shmem_present} file_cache_kb={start_file_cache} "
    f"reclaimable_kb={start_reclaimable}",
    flush=True,
)

pool = []
end = duration_end(duration)

penalty = 0
global_guard_logged = False

while running and time.time() < end:
    try:
        with open(state_file) as f:
            requested_pct = int(f.read().strip())
    except (OSError, ValueError):
        requested_pct = 0

    effective_pct = max(0, min(100, requested_pct - penalty))
    target = max(0, min(total * effective_pct / 100.0, total - SAFE_FREE))

    used = get_mem()[1]
    allocated = False
    guard_blocked = False

    if used < target:
        available_global = global_available()
        if available_global < SAFE_FREE_MIN_KB:
            guard_blocked = True
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
            try:
                pool.append(bytearray(ALLOC_CHUNK_BYTES))
                allocated = True
            except MemoryError:
                penalty += PENALTY_STEP
                time.sleep(5)

    elif used > target + RELEASE_MARGIN_KB and pool:
        pool.pop()

    if not guard_blocked:
        global_guard_logged = False

    if allocated:
        penalty = max(0, penalty - PENALTY_STEP)
    elif penalty > 0:
        penalty = max(0, penalty - 1)

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
# CPU worker
# =============================================================================
run_on_cpu() {
    taskset -c "$1" bash -c '
STATE=$1
DURATION=$2
END_DELAY_MAX=$3
CPU_ID=$4
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

_terminated=0
trap "_terminated=1" TERM

while [[ "$DURATION" == "infinite" ]] || (( SECONDS < start + DURATION )); do
    (( _terminated )) && break

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
        printf -v idle_sec "0.%03d" "$idle_ms"
        sleep "$idle_sec"
    fi
done

if [[ "$DURATION" != "infinite" ]] && (( END_DELAY_MAX > 0 )) && ! (( _terminated )); then
    END_DELAY=$(( RANDOM % (END_DELAY_MAX + 1) ))
    if (( END_DELAY > 0 )); then
        echo "[END_DELAY] cpu=$CPU_ID sleep ${END_DELAY}s before exit"
        # 可中断的 END_DELAY：每秒检查 SIGTERM
        end_at=$(( SECONDS + END_DELAY ))
        while (( SECONDS < end_at )) && ! (( _terminated )); do
            sleep 1
        done
    fi
fi' _ "$CPU_STATE_FILE" "$DURATION" "$END_DELAY_MAX" "$1" &
    CHILD_PIDS+=("$!")
}

# =============================================================================
# start
# =============================================================================
if (( START_DELAY_MAX > 0 )); then
    START_DELAY=$(random_delay "$START_DELAY_MAX")
    echo "[START_DELAY] sleep ${START_DELAY}s (range: 0-${START_DELAY_MAX}s)"
    sleep "$START_DELAY"
fi

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

        if [[ -d /sys/devices/system/node/node$n ]]; then
            echo "[NUMA] node=$n"
            memory_worker "$n" "$MEM_STATE_FILE" "$DURATION" "$END_DELAY_MAX" "$n" &
            CHILD_PIDS+=("$!")
        else
            echo "[WARN] skip invalid NUMA node $n"
        fi

    done

else
    memory_worker "global" "$MEM_STATE_FILE" "$DURATION" "$END_DELAY_MAX" &
    CHILD_PIDS+=("$!")
fi

# CPU workers
for c in "${CPU_ARRAY[@]}"; do
    run_on_cpu "$c"
done

wait
