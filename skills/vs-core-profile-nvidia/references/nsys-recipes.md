# Nsight Systems Recipe Library

Concrete, verified CLI invocations for `nsys` (Nsight Systems) on Linux. Each recipe names the goal, the command, and the follow-up to interpret the output. Flags correspond to **`nsys` 2026.2 (CUDA 13.2)** as documented at the [Nsight Systems User Guide](https://docs.nvidia.com/nsight-systems/UserGuide/index.html).

Older versions: most flags are stable across 2023.x → 2026.x. Where a flag is version-pinned, this reference notes the minimum version. Run `nsys --help`, `nsys profile --help` on your installed version when in doubt.

## Pre-flight

```bash
# Version
nsys --version
nsys profile --help | head -50

# What's available on this host?
nsys profile --help | grep -A1 'trace:\|backtrace:\|sample:\|capture-range:'

# Dry-run (validates flags without executing)
nsys profile --dry-run -t cuda,nvtx /bin/true
```

## Top-level command structure

```
nsys <subcommand> [options] [-- <target> [args]]

Subcommands:
  profile     -- collect a session (most-used)
  start       -- start collection (paired with stop)
  stop        -- stop a started collection
  cancel      -- abort current collection
  shutdown    -- shut down launched daemon
  launch      -- launch under nsys without immediate collect
  analyze     -- recipe-style multi-rank analysis
  export      -- convert .nsys-rep to other formats
  stats       -- summary stats from a .nsys-rep
  status      -- check current collection
  recipe      -- run a built-in analysis recipe
  sessions    -- list active sessions
  service     -- daemon control
```

`nsys profile` is the single most-used. The other subcommands are specialty tools.

## `nsys profile` — flag catalog

The most-asked-about flags, with verified semantics from current docs:

### Tracing API selection

| Flag | Meaning |
|---|---|
| `-t/--trace <list>` | Comma-separated APIs: `cuda`, `nvtx`, `osrt` (OS runtime), `cudnn`, `cublas`, `cublas-verbose`, `cusolver`, `cusparse`, `cudla`, `dx11`, `dx12`, `openmp`, `mpi`, `nccl`, `ucx`, `openxr`, `vulkan`, `gds`, `s3`, `wddm`, `python-gil`, `nvvideo`, `tegra-accelerators`, `oshmem`, `none`. **Multiple selectable.** |
| `--cuda-graph-trace {graph,node}` | Default `graph` (treat as one). `node` is high-overhead — only when investigating graph internals. |
| `--cuda-event-trace {auto,true,false}` | Default `false`. Enable for kernel-correlation when CUDA events are heavily used. |
| `--cuda-memory-usage {true,false}` | Default `false`. **Significant runtime overhead** — only when investigating memory bloat. |
| `--cuda-um-cpu-page-faults {true,false}` | Default `false`. Track CPU faults on managed memory. |
| `--cudabacktrace <list>` | `all`, `none`, `kernel`, `memory`, `sync`, `other`. Default `none`. Capture call stacks at CUDA API entry. |
| `--gpu-metrics-devices <list>` | **Note plural.** `all`, `<gpu-id>`, `none`, `help`. Collect GPU hardware metrics (SM Active, DRAM throughput, NVLink, etc.). Requires modprobe permission. |
| `--gpu-metrics-frequency <Hz>` | 10–200000. Default 10000. Higher = more samples but more overhead. |
| `--gpu-metrics-set <name>` | `general`, `compute`, `graphics`, etc. — predefined metric sets. List with `--gpu-metrics-set=help`. |
| `--osrt-threshold <ns>` | Default 1000 ns. OSRT calls shorter than this are filtered. |
| `--osrt-backtrace-threshold <ns>` | Default 80000 ns. Backtrace only on OSRT calls longer than this. |
| `--cpuctxsw {process-tree,system-wide,none}` | Default `process-tree`. Context-switch tracking. `system-wide` requires root. |

### CPU sampling and backtrace

| Flag | Meaning |
|---|---|
| `-s/--sample {process-tree,system-wide,xhv,xhv-system-wide,none}` | Default `process-tree`. CPU instruction-pointer sampling. |
| `--sampling-frequency <Hz>` | 100–8000. Default 1000. |
| `-b/--backtrace {fp,lbr,dwarf,none}` | DWARF most accurate but biggest files. LBR low-overhead (Skylake+/Zen3+). FP fastest but needs `-fno-omit-frame-pointer`. |

### Capture range and triggers

| Flag | Meaning |
|---|---|
| `--capture-range {none,cudaProfilerApi,hotkey,nvtx}` | Default `none` (capture entire app). `cudaProfilerApi` = capture between `cudaProfilerStart()` / `cudaProfilerStop()`. `nvtx` = capture inside named NVTX range. `hotkey` = manual trigger via key. |
| `--capture-range-end {none,stop,stop-shutdown,repeat[:N],repeat-shutdown:N}` | What happens at end of range. Default `stop-shutdown`. |
| `--nvtx-capture <pattern>` | Required with `--capture-range=nvtx`. Patterns: `range@domain`, `range`, `range@*`. |
| `--start-later <ms>` / `--delay <s>` | Delay collection after launch. Useful to skip warmup. |
| `--duration <s>` | Stop collection after duration regardless of target state. |

### Process and target control

| Flag | Meaning |
|---|---|
| `--target-processes {application-only,tree,group}` | Default depends on launch mode. `application-only` = just the launched binary. `tree` = launched + all children. `group` = process group (for MPI). |
| `-p/--pid <pid>` | Attach to running process. |
| `--ptrace` | Use ptrace for process attach (Linux). |
| `--mpi-impl {openmpi,mpich}` | Default `openmpi`. Required with `--trace=mpi`. |

### Output

| Flag | Meaning |
|---|---|
| `-o/--output <path>` | Output `.nsys-rep` file (without extension). |
| `-f/--force-overwrite {true,false}` | Default `false`. Required to overwrite existing report. |
| `--export <list>` | Auto-export after collection. Values: `arrow`, `arrowdir`, `hdf`, `jsonlines`, `parquetdir`, `sqlite`, `text`, `none`. |
| `--stats {true,false}` | Print summary stats after collection (default `false`). |
| `-V/--verbose` | Verbose collector logging. Useful for debugging collection failures. |

## Recipes by goal

### 1. System-wide timeline (start here, always)

```bash
# Default profile — CUDA + OSRT + NVTX + cuDNN + cuBLAS, GPU metrics on all GPUs
nsys profile \
  --trace=cuda,nvtx,osrt,cudnn,cublas \
  --gpu-metrics-devices=all \
  --gpu-metrics-frequency=10000 \
  -o ./nsys_out \
  ./app

# View timeline in GUI
nsys-ui ./nsys_out.nsys-rep   # or: open in Nsight Systems GUI

# Or print stats summary to stdout
nsys stats ./nsys_out.nsys-rep
```

What to read first: GPU idle %. If > 30%, the bottleneck is CPU-side / data loader / NCCL / Python — not the kernel. Move to PyTorch profiler or attach a CPU sampler before reaching for `ncu`.

### 2. PyTorch training trace (data-loader bottleneck hunt)

```bash
# Trace CUDA + NVTX + Python GIL + OSRT to see where the iteration time goes
nsys profile \
  --trace=cuda,nvtx,osrt,python-gil \
  --capture-range=cudaProfilerApi \
  -o ./pt_train \
  python train.py

# In train.py, scope the hot region:
import torch
torch.cuda.cudart().cudaProfilerStart()
for step, batch in enumerate(loader):
    if step == 5: torch.cuda.cudart().cudaProfilerStart()  # skip warmup
    if step == 10: torch.cuda.cudart().cudaProfilerStop(); break
    ...
```

What to read: **Python GIL stalls** appear as red on the timeline; large gaps between successive CUDA kernels indicate dispatch overhead or data-loader stall. PyTorch's own profiler ([ecosystem-complements.md](ecosystem-complements.md)) attributes to ops; `nsys` shows the underlying timeline.

### 3. NVTX range-scoped capture (avoid huge files)

```bash
# Code instrumentation:
# #include <nvtx3/nvtx3.hpp>
# {
#     nvtx3::scoped_range r{"hot_region"};
#     compute(...);
# }

# Capture only inside hot_region across all NVTX domains
nsys profile \
  --trace=cuda,nvtx \
  --capture-range=nvtx \
  --nvtx-capture='hot_region' \
  --capture-range-end=stop-shutdown \
  -o ./hot_only \
  ./app

# Match a specific domain
nsys profile \
  --trace=cuda,nvtx \
  --capture-range=nvtx \
  --nvtx-capture='hot_region@MyApp' \
  -o ./hot_only_mydomain \
  ./app
```

### 4. NCCL + multi-GPU trace

```bash
# Single node, multiple GPUs
nsys profile \
  --trace=cuda,nvtx,nccl \
  --gpu-metrics-devices=all \
  -o ./nccl_trace \
  python -m torch.distributed.run --nproc_per_node=8 train.py

# Multi-node MPI (one report per rank)
mpirun -n 16 \
  nsys profile \
    --trace=cuda,nvtx,nccl,mpi \
    --mpi-impl=openmpi \
    -o ./rank_%q{OMPI_COMM_WORLD_RANK} \
    ./mpi_app
```

What to read: NCCL kernels appear on dedicated streams. **Overlap = compute kernels firing simultaneously above NCCL on a different stream.** If NCCL kernels sit alone with no concurrent compute, overlap isn't happening — this is the most common multi-GPU perf bug. Fix is stream priority (`cudaStreamCreateWithPriority`) or moving to NVSHMEM-style SM-free collectives.

**Note:** `ncu` profiles of NCCL serialize the kernels and destroy the very overlap you're trying to measure ([NCCL #466](https://github.com/NVIDIA/nccl/issues/466)). For NCCL, use `nsys` exclusively (or `ncu --communicator shmem` on NCU 2026.1+).

### 5. Attach to running process

```bash
# Find PID
PID=$(pgrep -f myapp | head -1)

# Attach for 30 seconds
nsys profile \
  --trace=cuda,nvtx \
  -p $PID \
  --duration=30 \
  -o ./attached \
  --stop-on-exit=false
```

### 6. CUDA-graph-aware profiling

```bash
# Default (graph treated as one unit) — fast and useful for general timeline
nsys profile --trace=cuda --cuda-graph-trace=graph ./app

# Per-node detail (very high overhead) — only when investigating graph capture failures
nsys profile --trace=cuda --cuda-graph-trace=node ./app
```

`--cuda-graph-trace=node` records every node activity inside every graph instantiation. Trace size grows fast on inference workloads with hundreds of graph replays; use sparingly.

### 7. Cgroup / container scope

`nsys` does not have a native `--cgroup` flag. To scope to a container's process tree, attach via PID inside the container or launch under nsys:

```bash
# Inside container
docker exec -it <container> bash
nsys profile --trace=cuda --target-processes=tree -o /tmp/in_container ./app
docker cp <container>:/tmp/in_container.nsys-rep ./
```

For Kubernetes pod-level: launch the container with nsys as PID 1, or kubectl exec into a sidecar that has `nsys` and ptrace caps.

### 8. Long-running workload (continuous profiling)

```bash
# Capture range is hotkey — start/stop manually
nsys profile \
  --capture-range=hotkey \
  --hotkey=F1 \
  -o ./long_run \
  ./service &

# Press F1 to start collection, F1 again to stop. Service stays running.
```

Or use `nsys start`/`stop`:

```bash
# Launch service under nsys without immediate collection
nsys launch -- ./service

# Start collection
nsys start -o ./capture1

# ... wait for hot phase ...

# Stop and save
nsys stop
```

### 9. Multi-process / fork-aware

```bash
# Track child processes (default in tree mode)
nsys profile --target-processes=tree --trace=cuda \
  -o ./multi_proc \
  ./parent_app

# OR: track only the launched binary
nsys profile --target-processes=application-only --trace=cuda \
  -o ./parent_only \
  ./parent_app
```

For `torch.distributed.run`, default `tree` mode catches all worker processes.

### 10. JIT-warmup-aware capture

```bash
# Skip first N seconds (warmup), then collect for M seconds
nsys profile \
  --trace=cuda,nvtx \
  --start-later=10 \
  --duration=60 \
  -o ./hot_phase \
  ./app
```

For PyTorch+`torch.compile`: warmup MUST populate the inductor cache. First run picks suboptimal kernels ([pytorch/pytorch#164124](https://github.com/pytorch/pytorch/issues/164124)). Run a throwaway iteration before measuring.

## `nsys export` — convert for sharing/analysis

`.nsys-rep` is a proprietary SQLite-backed format. Export to:

```bash
# SQLite (most useful for scripting / SQL queries)
nsys export --type sqlite -o ./out.sqlite ./report.nsys-rep

# JSON Lines (for ad-hoc grep/jq)
nsys export --type jsonlines -o ./out.jsonl ./report.nsys-rep

# Apache Arrow (for Python/pandas)
nsys export --type arrow -o ./out.arrow ./report.nsys-rep

# HDF5 (for scientific computing pipelines)
nsys export --type hdf -o ./out.h5 ./report.nsys-rep

# Text (human-readable summary)
nsys export --type text -o ./out.txt ./report.nsys-rep
```

**Sharing a profile with teammates on different OS:** use `nsys export --type sqlite` then [nsys2json](https://github.com/chenyu-jiang/nsys2json) (community) to produce Chrome trace JSON viewable in [Perfetto UI](https://ui.perfetto.dev/). `.nsys-rep` is **not directly Perfetto-uploadable**.

## `nsys stats` — quick summary

```bash
# Default report (15 reports including cudaapi, gputrace, gpukernsum, gpumemops)
nsys stats ./report.nsys-rep

# Specific reports only
nsys stats --report cuda_gpu_kern_sum ./report.nsys-rep      # GPU kernel summary
nsys stats --report cuda_gpu_mem_time_sum ./report.nsys-rep  # Memory ops by time
nsys stats --report osrt_sum ./report.nsys-rep               # OS runtime calls
nsys stats --report nvtx_sum ./report.nsys-rep               # NVTX range summary

# CSV output for scripting
nsys stats --format csv --output ./stats.csv ./report.nsys-rep

# List available reports
nsys stats --help
```

## `nsys recipe` — multi-rank analysis recipes

```bash
# List built-in recipes
nsys recipe list

# Common: communication-computation overlap across ranks
nsys recipe nccl_gpu_proj_sum --input ./rank_*.nsys-rep --output ./overlap.csv

# Critical-path analysis on multi-rank
nsys recipe critical_path --input ./rank_*.nsys-rep --output ./critical.csv
```

For deeper multi-rank analysis Meta's Holistic Trace Analysis (HTA) is more capable — see [ecosystem-complements.md](ecosystem-complements.md).

## GPU metrics — what's collected and what's available

`--gpu-metrics-devices=all` collects, per GPU, on a sampling interval (default 10 kHz):

| Metric category | Examples |
|---|---|
| Compute | SM Active %, SM Issue %, Tensor Active % |
| Memory | DRAM Read/Write Throughput, L2 Read/Write Throughput |
| NVLink | NVLink Total Bytes, NVLink RX/TX |
| PCIe | PCIe Read/Write Throughput |
| Power | GPU Power, GPU Temperature |

List per-arch metric sets:

```bash
nsys profile --gpu-metrics-set=help
# Output examples (per arch):
#   ga100, ga10x, ad102, gh100, gb100, gb20x, ...
# Sets: 'general', 'compute', 'graphics', 'tensor', 'memory', 'nvlink'
```

**Hopper / Blackwell metrics:** require nsys ≥ 2024.5 / ≥ 2025.x respectively. Older nsys reports "no metrics available" silently. Verify with `nsys profile --gpu-metrics-set=help` on the install.

**Conflicts:**
- DCGM running → "Some GPUs are not supported" ([forum 294781](https://forums.developer.nvidia.com/t/issue-with-gpu-metrics-collection-for-nvidia-a100-on-nsight-systems/294781)). Tear down DCGM DaemonSet (not just the service) before profiling.
- vGPU → NVLink metrics unavailable.
- Jetson Orin → `--gpu-metrics-devices` NOT supported ([forum 288503](https://forums.developer.nvidia.com/t/nsys-does-not-support-gpu-metrics-device-for-jetson-agx-orin/288503)). Use `tegrastats`.

## NVTX integration

NVTX ranges (push/pop or RAII) appear as colored bands on the `nsys-ui` timeline, attributed to the source thread. Domains namespace ranges (e.g., `MyApp` vs `cuDNN`).

```cpp
// C++ code
#include <nvtx3/nvtx3.hpp>

void compute() {
    nvtx3::scoped_range r{"compute"};  // RAII, auto-pop
    // ...
}

// With domain
struct MyDomain {
    static constexpr char const* name{"MyApp"};
};
void hot() {
    nvtx3::scoped_range_in<MyDomain> r{"hot_region"};
    // ...
}
```

Python:

```python
import nvtx
with nvtx.annotate("epoch", color="blue"):
    train_one_epoch()
```

For PyTorch, `torch.cuda.nvtx.range_push("name")` / `range_pop()`. For TensorRT-LLM and many libraries, NVTX is auto-emitted — turn on with `--trace=nvtx`.

## Common errors and workarounds

| Error / symptom | Cause | Workaround |
|---|---|---|
| "Unable to launch CUDA agent" | Driver mismatch or CUPTI loaded from wrong path | Verify `LD_LIBRARY_PATH` doesn't pull stale `libcupti`. Match driver to toolkit version. |
| "Some GPUs are not supported" with `--gpu-metrics-devices=all` | DCGM running, or vGPU, or Jetson | Stop DCGM DaemonSet; or remove flag for non-supported GPUs |
| Empty timeline | Wrong `--trace` selection or `--capture-range` never triggered | Verify cudaProfilerStart/Stop was called; or remove `--capture-range` |
| Massive `.nsys-rep` (multi-GB) | `--cuda-graph-trace=node` or long capture | Use `graph` mode; shorten capture; use NVTX scoping |
| "Profiling is not supported on device 0 as it uses WSL" | WSL on Windows 10 | Need Windows 11 + driver 525+ ([forum 260814](https://forums.developer.nvidia.com/t/error-profiling-is-not-supported-on-device-0-as-it-uses-the-windows-subsystem-for-linux-wsl/260814)) |
| `nsys` segfaults on multi-rank with NCCL 2.14.3 | Regression after NCCL 2.10.3 ([NCCL #785](https://github.com/NVIDIA/nccl/issues/785)) | Use NCCL 2.18.x+ |
| Hang with NCCL_P2P_USE_CUDA_MEMCPY=1 | Driver-side hang ([NCCL #1480](https://github.com/NVIDIA/nccl/issues/1480)) | Unset env var |
| GPU metrics randomly drop near short kernels | High-freq sampling races short kernels ([forum 363103](https://forums.developer.nvidia.com/t/nsight-systems-gpu-metrics-become-unaligned-or-empty-near-a-short-kernel-at-higher-sampling-frequencies/363103)) | Lower `--gpu-metrics-frequency` (10000 → 5000) |
| Ray + Nsys gpu-metrics fails ([verl #2438](https://github.com/verl-project/verl/issues/2438)) | Container + Ray init order | Set gpu-metrics in main process only |
| Multi-process trace incomplete | `--target-processes=application-only` instead of `tree` | Use `tree` for distributed launches |

## Output artifact layout

After `nsys profile`:

```
./nsys_out.nsys-rep        # main report (binary, SQLite-backed)
./nsys_out.qdrep           # legacy alias (older nsys versions)
```

`.nsys-rep` opens in `nsys-ui` desktop app. For sharing or programmatic analysis, export (see above).

## Quick-reference card

```bash
# I want to... | ...run this
System timeline                       | nsys profile -t cuda,nvtx,osrt,cudnn,cublas --gpu-metrics-devices=all -o out ./app
PyTorch training profile              | nsys profile -t cuda,nvtx,osrt,python-gil --capture-range=cudaProfilerApi -o pt ./train.py
NVTX-scoped capture                   | nsys profile -t cuda,nvtx --capture-range=nvtx --nvtx-capture='hot@MyApp' -o hot ./app
NCCL multi-GPU                        | nsys profile -t cuda,nvtx,nccl --gpu-metrics-devices=all -o nccl ./app
Attach to running PID                 | nsys profile -p $PID --duration=30 -o attached
CUDA graphs node-level (high overhead)| nsys profile -t cuda --cuda-graph-trace=node -o graph ./app
JIT-warmup skip                       | nsys profile --start-later=10 --duration=60 -o hot ./app
Stats only                            | nsys profile -t cuda --stats=true ./app
Convert to SQLite                     | nsys export --type sqlite -o out.sqlite report.nsys-rep
Convert to Chrome trace JSON          | nsys export --type sqlite ... → community nsys2json → Perfetto UI
Multi-rank MPI                        | mpirun -n N nsys profile -t cuda,nvtx,nccl,mpi -o rank_%q{OMPI_COMM_WORLD_RANK} ./mpi_app
List available GPU metrics            | nsys profile --gpu-metrics-set=help
```

## References

- [Nsight Systems User Guide](https://docs.nvidia.com/nsight-systems/UserGuide/index.html)
- [Nsight Systems Release Notes](https://docs.nvidia.com/nsight-systems/ReleaseNotes/index.html)
- [Michael Carilli — Favorite nsys commands for PyTorch](https://gist.github.com/mcarilli/376821aa1a7182dfcf59928a7cde3223) — NVIDIA staff practitioner gist
- [PyTorch automated trace collection blog (Meta + NVIDIA)](https://pytorch.org/blog/automated-trace-collection/)
- [eunomia GPU profiling tools survey](https://eunomia.dev/blog/2025/04/21/gpu-profiling-under-the-hood-an-implementation-focused-survey-of-modern-accelerator-tracing-tools/)
- [NCCL #466 — ncu hangs collectives](https://github.com/NVIDIA/nccl/issues/466)
- [NVIDIA forum 363103 — gpu-metrics drop near short kernels](https://forums.developer.nvidia.com/t/nsight-systems-gpu-metrics-become-unaligned-or-empty-near-a-short-kernel-at-higher-sampling-frequencies/363103)
- [NVIDIA forum 294781 — nsys + DCGM conflict](https://forums.developer.nvidia.com/t/issue-with-gpu-metrics-collection-for-nvidia-a100-on-nsight-systems/294781)
- [verl #2438 — Ray + nsys init order](https://github.com/verl-project/verl/issues/2438)
- [pytorch/pytorch #164124 — torch.compile autotune cold-cache picks wrong kernel](https://github.com/pytorch/pytorch/issues/164124)
