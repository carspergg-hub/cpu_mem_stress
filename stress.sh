#!/bin/bash
# -----------------------------------------------------------------------------
# CPU + Memory 压力测试脚本 (V4.1: 终极企业版)
# 特性：
#   - 独立波形发生器 (CPU 与内存波动完全异步解耦)
#   - 动态校准 (自动抵抗 CPU 过热降频与 Cgroup 节流)
#   - 内核调度防抖 (锁定 1000ms 燃烧周期，避开底层 4ms 调度误差)
#   - 内存防 Swap 风暴 (限流释放与强制 GC，保障系统 I/O 平滑)
#   - 进程组级清理 (Kill -$$ 彻底杜绝压测孤儿进程逃逸)
# -----------------------------------------------------------------------------

# ==============================
# 参数解析与帮助信息
# ==============================
if [[ $# -lt 6 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "======================================================================="
    echo " 🚀 极速 CPU + Memory 压力测试脚本 (V4.1)"
    echo "======================================================================="
    echo "命令格式:"
    echo "  $0 <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]"
    echo ""
    echo "必填参数:"
    echo "  cpu_min   : CPU 占用率下限 (0-99%)"
    echo "  cpu_max   : CPU 占用率上限 (0-99%)"
    echo "  cpu_step  : CPU 波浪周期 (秒) - 多久变动一次目标频率"
    echo "  mem_min   : 内存占用率下限 (0-99%)"
    echo "  mem_max   : 内存占用率上限 (0-99%)"
    echo "  mem_step  : 内存波浪周期 (秒) - 多久变动一次目标水位"
    echo ""
    echo "可选参数:"
    echo "  duration  : 压测总时长 (秒)。默认值: 60"
    echo ""
    echo "使用示例:"
    echo "  $0 20 80 1 40 90 10 300"
    echo "  -> CPU: 20%-80% 波动 (每 1s 更新)"
    echo "  -> MEM: 40%-90% 波动 (每 10s 更新)"
    echo "  -> 时长: 持续 300 秒"
    echo "======================================================================="
    exit 1
fi

# 参数赋值
CPU_MIN=$1
CPU_MAX=$2
CPU_WAVE_SEC=$3
MEM_MIN=$4
MEM_MAX=$5
MEM_WAVE_SEC=$6
DURATION=${7:-60}

# 安全阈值校验 (最高锁定 99%，给内核和 SSH 留出极限调度空间)
MAX_LIMIT=99 
[[ $CPU_MIN -gt $MAX_LIMIT ]] && CPU_MIN=$MAX_LIMIT
[[ $CPU_MAX -gt $MAX_LIMIT ]] && CPU_MAX=$MAX_LIMIT
[[ $MEM_MIN -gt $MAX_LIMIT ]] && MEM_MIN=$MAX_LIMIT
[[ $MEM_MAX -gt $MAX_LIMIT ]] && MEM_MAX=$MAX_LIMIT

# 内存盘共享状态文件 (基于进程 PID 防止多开冲突)
CPU_STATE_FILE="/dev/shm/cpu_p_$$"
MEM_STATE_FILE="/dev/shm/mem_p_$$"

# ==============================
# 进程组级彻底清理
# ==============================
cleanup() {
    echo -e "\n[Terminating] Cleaning up process group and temp files..."
    trap '' SIGINT SIGTERM EXIT # 屏蔽信号防止重入引发的死锁
    rm -f "$CPU_STATE_FILE" "$MEM_STATE_FILE" 2>/dev/null
    
    # 击杀整个进程组，防止孙子进程逃逸
    kill -TERM -$$ 2>/dev/null || kill 0 2>/dev/null
    wait 2>/dev/null
    echo "[Success] Stress test stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# ==============================
# 1. 独立波形控制器
# ==============================
value_controller() {
    local min=$1 max=$2 step=$3 file=$4
    local end=$(( SECONDS + DURATION ))
    
    while (( SECONDS < end )); do
        local val=$min
        if (( max > min )); then
            val=$(( RANDOM % (max - min + 1) + min ))
        fi
        
        # 兜底文件创建，防止被系统 tmpfs 意外清理导致 1<> 报错
        [[ ! -f "$file" ]] && touch "$file"
        
        # 使用 1<> 非截断原子覆盖写，消除读脏数据隐患
        printf "%-3s\n" "$val" 1<> "$file"
        sleep "$step"
    done
}

# ==============================
# 2. 内存压力 Worker (防 Swap 风暴版)
# ==============================
memory_worker() {
    exec python3 -c '
import time, sys, gc

mem_state_file = sys.argv[1]
duration = int(sys.argv[2])
chunk_size = 20 * 1024 * 1024  # 每次步进 20MB
memory_pool = []

def get_mem_info():
    with open("/proc/meminfo") as f:
        total = avail = 0
        for line in f:
            if line.startswith("MemTotal:"): total = int(line.split()[1])
            elif line.startswith("MemAvailable:"): avail = int(line.split()[1])
        return total, avail

total, _ = get_mem_info()
end_time = time.time() + duration

# 防 Swap 风暴限流器
last_release_time = 0
release_cooldown = 1.0  # 最快 1 秒释放一次，给 kswapd 留足喘息时间

while time.time() < end_time:
    try:
        with open(mem_state_file, "r") as f:
            target_pct = int(f.read().strip())
    except:
        target_pct = 0

    target_used_kb = total * target_pct / 100.0
    _, avail = get_mem_info()
    current_used = total - avail

    if current_used < target_used_kb:
        try: memory_pool.append(bytearray(chunk_size))
        except MemoryError: pass
    elif current_used > target_used_kb + (50 * 1024) and memory_pool:
        current_time = time.time()
        # 限流释放并强制回收 RSS
        if current_time - last_release_time >= release_cooldown:
            memory_pool.pop()
            gc.collect() 
            last_release_time = current_time
    
    time.sleep(0.3)
' "$MEM_STATE_FILE" "$DURATION"
}

# ==============================
# 3. CPU 燃烧 Worker (动态校准 & 绝对时间锁定版)
# ==============================
run_on_cpu() {
    local cpu_idx=$1
    taskset -c "$cpu_idx" bash -c '
        STATE_F=$1; DUR=$2; MIN=$3
        
        # 封装动态校准函数：测试当前核心 1 毫秒能跑多少次空循环
        calibrate() {
            local cal=50000 s e diff
            s=$(date +%s%N)
            for ((i=0; i<cal; i++)); do ((x=i*i)); done
            e=$(date +%s%N)
            diff=$(( (e-s)/1000000 ))
            (( diff <= 0 )) && diff=1
            echo $(( cal / diff ))
        }
        
        L_MS=$(calibrate)
        
        # 使用真实时钟锁定结束时间，彻底解决系统卡顿导致的时间漂移
        end_time=$(( SECONDS + DUR ))
        last_cal=$SECONDS
        
        while (( SECONDS < end_time )); do
            # 每隔 10 秒重新校准算力，抵抗 CPU 热降频或 Cgroup 节流
            if (( SECONDS - last_cal >= 10 )); then
                L_MS=$(calibrate)
                last_cal=$SECONDS
            fi
            
            # 零 Fork 极速读取内存盘状态
            if read -r p < "$STATE_F" 2>/dev/null; then
                p=${p%% *}; [[ "$p" =~ ^[0-9]+$ ]] || p=$MIN
            else p=$MIN; fi
            
            # 燃烧阶段 (1000ms 周期)
            burn=$(( p * L_MS * 10 ))
            for (( i=0; i<burn; i++ )); do ((x=i*i)); done
            
            # 休眠阶段: 即使 99% 时也休眠 10ms，稳稳避开 Linux 4ms 最小调度粒度误差
            idle=$(( 100 - p ))
            (( idle > 0 )) && sleep "0.$(printf "%02d" "$idle")"
        done
    ' _ "$CPU_STATE_FILE" "$DURATION" "$CPU_MIN" &
}

# ==============================
# 启动序列
# ==============================
CPU_COUNT=$(nproc)
# 强制隔离 CPU0，保证底层系统中断和 SSH 守护进程的绝对响应能力
CPU_LIST=$(seq 1 $((CPU_COUNT - 1))) 

echo "------------------------------------------------"
echo "CPU Range   : $CPU_MIN% - $CPU_MAX% (Step: ${CPU_WAVE_SEC}s)"
echo "MEM Range   : $MEM_MIN% - $MEM_MAX% (Step: ${MEM_WAVE_SEC}s)"
echo "Duration    : ${DURATION}s"
echo "Workers     : $((CPU_COUNT - 1)) CPU cores (Excluding CPU0)"
echo "Features    : Dynamic Calib, Anti-Swap, Kernel-Safe Sleep"
echo "------------------------------------------------"

# 初始化并确保共享文件存在
touch "$CPU_STATE_FILE" "$MEM_STATE_FILE"
printf "%-3s\n" "$CPU_MIN" > "$CPU_STATE_FILE"
printf "%-3s\n" "$MEM_MIN" > "$MEM_STATE_FILE"

# 1. 启动内存监控 Worker
memory_worker &

# 2. 启动异步波形发生器 (完全解耦)
value_controller "$CPU_MIN" "$CPU_MAX" "$CPU_WAVE_SEC" "$CPU_STATE_FILE" &
value_controller "$MEM_MIN" "$MEM_MAX" "$MEM_WAVE_SEC" "$MEM_STATE_FILE" &

# 3. 在独立核心上启动 CPU 燃烧器
for i in $CPU_LIST; do
    run_on_cpu "$i"
done

# 等待所有后台任务完成
wait
