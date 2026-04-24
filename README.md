#  Extreme Wave Stressor: 极速 CPU & Memory 压力波动发生器

**Extreme Wave Stressor** 是一个专为严苛企业级环境和云原生容器（Cgroup）设计的极速、无依赖的系统压力测试脚本。它不仅能让 CPU 和内存按照你设定的频率产生**完全异步的波浪式压力**，还从内核调度和底层 I/O 层面解决了一般压测脚本在极端压力下容易出现的“时间漂移”、“精度丢失”和“系统死锁”问题。

## ✨ 核心特性 (Hardcore Features)

- 🌊 **异步双波形解耦**：CPU 和内存拥有独立的控制器，可在设定区间内按不同周期独立波动，模拟真实且复杂的突发业务流量。
- ⏱️ **内核调度级防抖 (Kernel-Safe Sleep)**：摒弃传统的微秒级休眠。锁定 1000ms 基础燃烧周期，确保 `sleep` 粒度远大于 Linux 调度器的最小让渡误差（通常为 4ms），即使在 99% 占用率下依然精准。
- 🛡️ **防 Swap 风暴 (Anti-Swap Storm)**：内建内存限流释放与强制垃圾回收（`gc.collect()`）机制。避免压力突降时瞬间释放海量内存导致内核 `kswapd` 进程打满 CPU 而卡死系统。
- 🔄 **抗降频动态校准 (Dynamic Calibration)**：运行期间每隔 10 秒自动重新压测并校准核心算力，完美抵抗 CPU 过热降频（Thermal Throttling）或 Cgroup 算力节流导致的压测精度漂移。
- 🚀 **零开销 / 零竞态锁**：
  - 彻底干掉紧密循环中的 `fork` 操作，大量使用 Bash 内建特性（如 `$SECONDS`）。
  - 使用 `/dev/shm`（内存盘）进行 IPC 通信。
  - 极客级的文件读写：使用 `1<>` 描述符进行**非截断原子级覆盖写**，彻底消除 `O_TRUNC` 带来的空读与脏数据掉载问题。
- 🆘 **绝对防失联与防逃逸**：
  - 自动隔离 `CPU0`，将其让渡给系统中断和 SSH 守护进程，即使 99% 全局压测也能流畅敲入 `Ctrl+C`。
  - 进程组级捕获（`kill -- -$$`），退出时寸草不生，杜绝孙子进程（Zombie Worker）逃逸耗尽资源。

---

## 🛠️ 环境依赖

无需安装任何第三方压测包（如 `stress-ng`），开箱即用：
- **Bash** (v4.0+)
- **Python 3** (调用内建库进行精准的内存申请与释放)
- 标准 Linux 核心组件 (`nproc`, `taskset`, `/proc/meminfo`)

---

## 🚀 快速开始

### 1. 下载脚本并赋予权限
```bash
wget https://raw.githubusercontent.com/carspergg-hub/cpu_mem_stress/refs/heads/main/stress.sh
chmod +x stress.sh
### 2. 命令格式
./stress.sh <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]
### 3. 参数说明
参数,类型,范围,说明
cpu_min,必填,0 - 99,CPU 占用率下限 (%)
cpu_max,必填,0 - 99,CPU 占用率上限 (%)
cpu_step,必填,> 0,CPU 波浪周期 (秒) - 多久变动一次目标频率
mem_min,必填,0 - 99,内存占用率下限 (%)
mem_max,必填,0 - 99,内存占用率上限 (%)
mem_step,必填,> 0,内存波浪周期 (秒) - 多久变动一次目标水位
duration,可选,> 0,压测总时长 (秒)。默认值: 60

注：为保证系统可调度性，脚本内部硬编码了最大占用率安全阈值为 99%)

🎯 典型场景示例
场景 A：云原生容器弹性伸缩 (HPA) 测试
模拟 CPU 突发脉冲，同时内存缓慢增长。
# CPU：在 10% 到 90% 之间剧烈震荡（每 2 秒变化一次）
# 内存：在 60% 到 80% 之间平缓波动（每 30 秒变化一次）
# 时长：持续运行 5 分钟 (300 秒)
./stress.sh 10 90 2 60 80 30 300
场景 B：数据库节点高负载压测
模拟高内存占用和中等偏高的 CPU 稳定波动。
# CPU：在 60% 到 75% 之间小幅波动（每 5 秒变化一次）
# 内存：高水位 85% 到 95% 之间波动（每 10 秒变化一次）
# 时长：持续运行 10 分钟 (600 秒)
./stress.sh 60 75 5 85 95 10 600
场景 C：获取帮助信息
./stress.sh -h

🛑 手动干预与干掉压测
脚本设计为响应优先。当你想立刻停止所有压力时，直接按下 Ctrl+C 即可。

如果由于终端断开等意外情况需要手动强制清理：
# 终止进程组
pkill -TERM -f stress.sh


💡 工作原理架构图 (简述)
[Main Process] (CPU0 Exempt)
  │
  ├──> [CPU Wave Controller] ---> writes to ---> /dev/shm/cpu_p_$$ (1<> mode)
  ├──> [MEM Wave Controller] ---> writes to ---> /dev/shm/mem_p_$$ (1<> mode)
  │
  ├──> [Python Memory Worker] <--- reads from -- /dev/shm/mem_p_$$ (0.3s poll)
  │      └─> allocate/pop bytearrays + gc.collect()
  │
  ├──> [Bash CPU Worker (Core 1)] <--- reads from -- /dev/shm/cpu_p_$$
  │      ├─> calibrate() every 10s
  │      └─> tight matrix loop + sleep offset
  │
  └──> [Bash CPU Worker (Core N)] ...

📜 License
MIT License. 自由使用，欢迎提交 PR 共同优化！
