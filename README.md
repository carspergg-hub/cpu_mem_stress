# CPU & Memory 压力测试工具

`stress.sh` 是一个面向 Linux 裸机、普通云主机和 NUMA 环境的 CPU/内存压力测试脚本。它可以按指定区间动态调节 CPU 和内存压力，并支持随机启动延迟、随机结束释放延迟，适合批量压测时错峰启动和错峰退出。

## 功能特性

- CPU 和内存目标独立控制。
- CPU 目标按整机总 CPU 使用率统计，基于 `/proc/stat` 的总 CPU 行。
- 在 Linux 裸机或普通云主机中，CPU 目标表示加压后的系统总 CPU 使用率。
- 如果脚本进程被 `taskset` 等方式限制到部分 CPU，worker 只能在允许 CPU 上加压，可能无法把整机总 CPU 推到目标值。
- 检测到 `numactl` 时，内存 worker 支持 NUMA preferred 分配。
- 内存分配带安全保护，尽量降低 reclaim、swap storm 和 kswapd 风暴风险。
- 设置有限 `duration` 时，脚本会自动退出并释放自身申请的内存。
- 支持 `start_delay_max` 和 `end_delay_max`，用于多实例压测时随机错峰。

## 运行依赖

- Linux，且可读取 `/proc/stat` 和 `/proc/self/status`
- `bash`
- `python3`
- `taskset`
- `nproc`
- 支持 `%N` 的 GNU `date`
- `numactl` 可选；存在时用于 NUMA preferred 分配

## 下载

```bash
wget https://raw.githubusercontent.com/carspergg-hub/cpu_mem_stress/refs/heads/main/stress.sh
chmod +x stress.sh
```

## 使用方式

```bash
./stress.sh <start_delay_max> <end_delay_max> <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `start_delay_max` | 启动前随机等待的最大秒数。实际等待时间为 `0..start_delay_max` 秒。 |
| `end_delay_max` | 有限 `duration` 结束后，worker 释放/退出前随机等待的最大秒数。 |
| `cpu_min` | CPU 使用率目标下限，百分比，表示加压后的系统总 CPU 使用率。 |
| `cpu_max` | CPU 使用率目标上限，百分比，表示加压后的系统总 CPU 使用率。 |
| `cpu_step` | CPU 目标值随机变化间隔，单位秒。 |
| `mem_min` | 估算内存使用率目标下限，百分比。 |
| `mem_max` | 估算内存使用率目标上限，百分比。 |
| `mem_step` | 内存目标值随机变化间隔，单位秒。 |
| `duration` | 可选，运行时长，单位秒。省略或使用 `infinite` 表示一直运行，直到手动停止。 |

注意：`cpu_step` 和 `mem_step` 表示“随机目标值变化间隔”，不是正弦波、锯齿波或平滑曲线周期。

## 使用示例

运行 2 小时，不设置启动/结束延迟，CPU 控制在 30%-40%，内存控制在 55%-75%；CPU 目标每 300 秒随机变化一次，内存目标每 600 秒随机变化一次：

```bash
./stress.sh 0 0 30 40 300 55 75 600 7200
```

启动前最多随机等待 60 秒，结束时最多随机等待 120 秒：

```bash
./stress.sh 60 120 30 70 30 50 80 60 3600
```

一直运行直到手动停止：

```bash
./stress.sh 0 0 20 60 10 40 70 30
```

## CPU 目标语义

脚本会读取 `/proc/stat` 的整机总 CPU 统计。CPU 控制器会动态调节 worker 压力，使系统总 CPU 使用率尽量接近当前随机选中的目标值。

脚本仍会读取 `/proc/self/status` 中的 `Cpus_allowed_list` 来决定 worker 可以绑定到哪些 CPU。如果脚本进程本身被限制到部分 CPU，统计口径仍是整机总 CPU，但脚本只能在允许 CPU 上加压，因此高目标值可能达不到。

如果系统里已有其它进程让 CPU 使用率超过 `cpu_max`，脚本只能把自身产生的 CPU 压力降到 0，不能降低其它进程消耗的 CPU。

## 内存目标语义

内存 worker 会估算当前已用内存：

- 全局模式：优先基于 `MemAvailable` 估算。
- NUMA 模式：基于节点 `MemFree`、文件缓存和可回收内存字段估算。

如果已有内存使用率高于 `mem_max`，脚本只能释放自己申请的内存，不能回收其它进程占用的内存。

脚本会保留安全水位。当全局可用内存低于保护阈值时，会暂停继续分配，降低触发系统回收和 swap 风暴的风险。

## NUMA 行为

检测到 `numactl` 时，脚本会读取：

```bash
/sys/devices/system/node/online
```

支持以下 NUMA 节点格式：

```text
0-1
0,2
0-3,8-10
```

每个有效 NUMA 节点都会启动一个内存 worker，并使用：

```bash
numactl --preferred=<node>
```

## 停止方式

前台运行时：

```bash
Ctrl+C
```

或在另一个 shell 中执行：

```bash
pkill -f stress.sh
```

## License

MIT License
