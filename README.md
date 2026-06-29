# CPU & Memory Stress Tool

`stress.sh` is a Linux CPU and memory stress script designed for cloud, cgroup, and NUMA environments. It can keep CPU and memory usage near configured target ranges, while supporting randomized start and end delays for staggered test runs.

## Features

- CPU and memory targets are controlled independently.
- CPU target is measured against the current process allowed CPU set from `Cpus_allowed_list`.
- On unrestricted bare metal, the CPU target is equivalent to total host CPU usage.
- In containers or cpuset-limited environments, only allowed CPUs are measured and stressed.
- Memory workers are NUMA-aware when `numactl` is available.
- Memory allocation uses safety guards to reduce reclaim and swap storms.
- Finite `duration` exits cleanly and releases allocated memory.
- Optional randomized `start_delay_max` and `end_delay_max` help stagger multiple stress processes.

## Requirements

- Linux with `/proc/stat` and `/proc/self/status`
- `bash`
- `python3`
- `taskset`
- `nproc`
- GNU `date` with `%N` support
- `numactl` is optional, used for NUMA preferred placement when available

## Download

```bash
wget https://raw.githubusercontent.com/carspergg-hub/cpu_mem_stress/refs/heads/main/stress.sh
chmod +x stress.sh
```

## Usage

```bash
./stress.sh <start_delay_max> <end_delay_max> <cpu_min> <cpu_max> <cpu_step> <mem_min> <mem_max> <mem_step> [duration]
```

## Parameters

| Parameter | Description |
| --- | --- |
| `start_delay_max` | Random startup delay upper bound in seconds. The script sleeps `0..start_delay_max` seconds before starting stress workers. |
| `end_delay_max` | Random exit/release delay upper bound in seconds after finite `duration` ends. |
| `cpu_min` | Lower CPU usage target percentage for the allowed CPU set. |
| `cpu_max` | Upper CPU usage target percentage for the allowed CPU set. |
| `cpu_step` | Seconds between random CPU target changes within `[cpu_min, cpu_max]`. |
| `mem_min` | Lower estimated memory usage target percentage. |
| `mem_max` | Upper estimated memory usage target percentage. |
| `mem_step` | Seconds between random memory target changes within `[mem_min, mem_max]`. |
| `duration` | Optional run duration in seconds. Use `infinite` or omit it to run until stopped. |

`cpu_step` and `mem_step` are random target change intervals. They are not sine-wave or smooth ramp intervals.

## Examples

Run for 2 hours, no start or end delay, keep CPU around 30-40%, keep memory around 55-75%, change CPU target every 300 seconds and memory target every 600 seconds:

```bash
./stress.sh 0 0 30 40 300 55 75 600 7200
```

Allow startup delay up to 60 seconds and exit delay up to 120 seconds:

```bash
./stress.sh 60 120 30 70 30 50 80 60 3600
```

Run until manually stopped:

```bash
./stress.sh 0 0 20 60 10 40 70 30
```

## CPU Target Semantics

The CPU controller samples `/proc/stat` for the CPUs listed in `/proc/self/status` under `Cpus_allowed_list`. It adjusts worker load so the measured usage for that allowed CPU set stays near the selected target.

If other processes are already using more CPU than `cpu_max`, the script can only reduce its own generated CPU pressure to zero. It cannot reduce CPU consumed by other processes.

## Memory Target Semantics

Memory workers estimate used memory as:

- Global mode: based on `MemAvailable` when available.
- NUMA mode: based on node `MemFree`, file cache, and reclaimable memory fields.

If existing memory usage is already above `mem_max`, the script can only release memory allocated by itself. It cannot reclaim memory owned by other processes.

The script keeps a safety reserve and pauses allocation when global available memory falls below the guard threshold.

## NUMA Behavior

When `numactl` is available, the script reads:

```bash
/sys/devices/system/node/online
```

It supports mixed node list formats such as:

```text
0-1
0,2
0-3,8-10
```

Each valid node gets a memory worker using `numactl --preferred=<node>`.

## Stop

```bash
Ctrl+C
```

Or from another shell:

```bash
pkill -f stress.sh
```

## License

MIT License
