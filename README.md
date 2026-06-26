# Extreme Wave Stressor: 极速 CPU & Memory 压力波动发生器

**Extreme Wave Stressor** 是一个面向云原生 / Cgroup / NUMA 架构的高精度 CPU & Memory 压力生成工具，用于模拟真实业务负载中的波动、突发与资源竞争行为。

相比传统 stress/stress-ng，该工具强调：
- 波形控制（Wave-based Load）
- CPU/Memory 解耦
- NUMA 感知执行
- 低调度误差与高时间稳定性

---

# ✨ 核心特性

## 🌊 双波形负载模型
- CPU 与 Memory 独立控制器
- 支持不同周期的动态波动
- 可模拟真实业务流量突刺

## 🧠 NUMA 感知执行（V7.3+ 修复）
- 自动读取 `/sys/devices/system/node/online`
- 支持 Linux bitmap/range/list 格式解析（如 `0-1`, `0,2`, `0-3,8-10`）
- 修复 node 越界问题（如 node 10 out of range）

## ⚙️ 内核级稳定设计
- CPU0 默认保留给系统中断
- /dev/shm 作为 IPC 通道
- 10s 自动 recalibration
- 防 CPU throttling 漂移

## 🛡️ 内存安全机制
- 自动 GC + 阶梯释放
- 防 kswapd 风暴
- 防 swap storm
- MemoryError 自动退避

## 🔄 动态校准机制
- CPU burn loop 动态校准
- 抗温控降频（thermal throttling）
- 抗 Cgroup CPU 限流

---

# 🚀 快速开始

## 1. 下载
```bash
wget https://raw.githubusercontent.com/carspergg-hub/cpu_mem_stress/refs/heads/main/stress.sh
chmod +x stress.sh
```

---

## 2. 使用方式

```bash
./stress.sh <start_delay_max> <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]
```

---

## 3. 参数说明

| 参数 | 说明 |
|------|------|
| start_delay_max | 启动前随机延迟上限（秒）。0 表示不延迟；60 表示随机延迟 0-60 秒 |
| cpu_min | CPU占用下限 (%) |
| cpu_max | CPU占用上限 (%) |
| cpu_step | CPU波动周期（秒） |
| mem_min | 内存占用下限 (%) |
| mem_max | 内存占用上限 (%) |
| mem_step | 内存波动周期（秒） |
| duration | 运行时间（秒，可选） |

---

# 🎯 使用示例

## 场景A：容器弹性测试
```bash
./stress.sh 0 10 90 2 60 80 30 300
```

## 场景B：数据库压力测试
```bash
./stress.sh 60 60 75 5 85 95 10 600
```

---

# ⚠️ NUMA 注意事项（V7.3+ 修复）

系统 NUMA 节点不一定连续，可能出现：

- 0-1（range）
- 0,2（list）
- 0-3,8-10（混合）

因此必须使用 kernel bitmap 展开逻辑，而不是 ls 解析。

已修复问题：
```
skip invalid NUMA node 0-1 ❌
```

---

# 🧪 架构说明

```
Main Process (CPU0 reserved)
   ├── CPU Wave Controller → /dev/shm/cpu_p_$$
   ├── MEM Wave Controller → /dev/shm/mem_p_$$
   ├── Python Memory Worker → NUMA node workers
   └── CPU Burn Workers → taskset pinned cores
```

---

# 🔥 V7.3.1 改进点

### ✔ NUMA修复
- 修复 bitmap/range 未展开问题
- 修复 node 越界（0-1 被误判）

### ✔ 稳定性增强
- NUMA preferred 模式
- 避免强绑定 membind

### ✔ 兼容性增强
- 支持 x86 / ARM / Kunpeng / Hygon

---

# 🛑 停止方式

```bash
Ctrl + C
pkill -f stress.sh
```

---

# 📜 License
MIT License
