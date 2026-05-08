# Ecosystem Complements — PyTorch Profiler, NVTX, DCGM, HTA, Perfetto

Currency: as-of 2026-04. PyTorch ≥ 2.10 / Kineto current trunk / NVTX v3.5.0-c-cpp / DCGM 4.x / HTA 0.6.x / Triton 3.x. Per-feature version pins live in the relevant subsection.

Nsight is not the only NVIDIA profiling tool — and often not the right first tool. This reference covers what `torch.profiler` / Kineto, NVTX, DCGM, Meta's Holistic Trace Analysis, Perfetto, and `cudaEvent` timing give you that Nsight does not. The operational companion to [nsys-recipes.md](nsys-recipes.md) and [ncu-recipes.md](ncu-recipes.md).

## PyTorch profiler + Kineto

**What it is:** PyTorch's built-in profiler. Backend is **Kineto**, which interfaces with CUPTI for kernel timestamps and CUPTI Range Profiler for counters. The framework-level entry point.

**Primary URLs:**
- API docs: https://docs.pytorch.org/docs/stable/profiler
- Tutorial: https://docs.pytorch.org/tutorials/recipes/recipes/profiler_recipe.html
- Kineto: https://github.com/pytorch/kineto

### Basic usage

```python
import torch
from torch.profiler import profile, record_function, ProfilerActivity, schedule

with profile(
    activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
    schedule=schedule(wait=1, warmup=1, active=3, repeat=1),
    on_trace_ready=torch.profiler.tensorboard_trace_handler('./tblog'),
    record_shapes=True,
    profile_memory=True,
    with_stack=True,
) as prof:
    for step, batch in enumerate(loader):
        with record_function("training_step"):
            output = model(batch)
            loss = output.sum()
            loss.backward()
            optimizer.step()
        prof.step()  # advance the schedule

# Or export Chrome trace JSON (any browser via Perfetto)
prof.export_chrome_trace("trace.json")
```

### Schedule-based capture

The `schedule` API cycles through phases:
- `wait` — do nothing (skip warmup steps).
- `warmup` — start CUPTI buffers but don't record.
- `active` — record N steps.
- `repeat` — repeat the cycle (avoids one giant trace file).

For multi-step training: `wait=1, warmup=1, active=3, repeat=2` captures 6 active steps total in two cycles of 3.

### When to use PyTorch profiler vs nsys

| Question | Tool |
|---|---|
| "Which Python op is slowest?" | PyTorch profiler — attributes to `aten::*` ops with stack traces. |
| "Which CUDA kernel is slowest?" | PyTorch profiler shows kernels but `nsys` shows the timeline more clearly. Use either. |
| "Where is GIL stalling?" | `nsys --trace=python-gil`. PyTorch profiler doesn't surface GIL. |
| "How does this op decompose into kernels?" | PyTorch profiler with `record_shapes=True`. |
| "Multi-GPU comm-compute overlap?" | `nsys` per-rank → Meta's HTA (next section). |
| "Kernel-level counters (DRAM bw, tensor active)?" | `ncu` (after nsys named the kernel). PyTorch profiler doesn't collect counters. |
| "Memory allocator behavior?" | PyTorch profiler with `profile_memory=True` shows allocations per op. |

**Rule of thumb:** PyTorch users start here. Escalate to `nsys` when framework-level attribution isn't enough; escalate to `ncu` when per-kernel counters are needed.

### Known footguns

| Issue | Cause | Workaround |
|---|---|---|
| `torch.utils.bottleneck` crashes with `num_workers > 0` ([pytorch #6313](https://github.com/pytorch/pytorch/issues/6313)) | Profiler init fails in DataLoader worker subprocess | Use modern `torch.profiler` API instead; or `num_workers=0` for bottleneck runs |
| `prof.export_chrome_trace` produces JSON TensorBoard can't load ([pytorch #95460](https://github.com/pytorch/pytorch/issues/95460)) | Bare array, no `{"traceEvents": [...]}` wrapper | Open in `chrome://tracing` or [Perfetto UI](https://ui.perfetto.dev/) directly; or wrap post-hoc |
| NCCL `all_reduce` profiled as host-only time ([pytorch #52246](https://github.com/pytorch/pytorch/issues/52246)) | recordFunction sees enqueue, not GPU completion | For collective time, read CUPTI events; HTA's critical-path module does this correctly |
| Adding CUPTI counters to `_ExperimentalConfig` destroys trace ([pytorch #125272](https://github.com/pytorch/pytorch/issues/125272)) | Pass-through path bug | Don't combine; collect counters with `ncu` separately |
| GPU ops mislabeled as `cpu_op` for FA / Triton ([pytorch #170319](https://github.com/pytorch/pytorch/issues/170319)) | Categorization bug PyTorch 2.9.1+ | Cross-check kernel names against `nsys`; expect to see Triton kernels in CUDA category as `triton_*` |
| Profiler hang in `_disable_profiler` with CUDA Graphs + cu118 ([pytorch #135003](https://github.com/pytorch/pytorch/issues/135003)) | Specific cu118 wheel bug | Use cu121+ wheels |
| Multi-process profiler regression PyTorch 2.12 ([pytorch #182373](https://github.com/pytorch/pytorch/issues/182373)) | Parent `torch.cuda.init()` + child spawn drops GPU activity | Use 2.10–2.11 if multi-process; or workaround with explicit child init |

## NVTX

**What it is:** NVIDIA Tools Extension. Annotation API for marking ranges in source code; `nsys` and `ncu` consume them as scoping primitives.

**Primary URLs:**
- Main: https://nvidia.github.io/NVTX/
- Repo: https://github.com/NVIDIA/NVTX
- NVIDIA blog (overview): https://developer.nvidia.com/blog/nvidia-tools-extension-api-nvtx-annotation-tool-for-profiling-code-in-python-and-c-c/

**NVTX v3 is header-only** — no library link required; just include and compile. Latest tag `v3.5.0-c-cpp` (2026-04). Python wrapper: `pip install nvtx` (Python 3.6+).

### C++ usage

```cpp
#include <nvtx3/nvtx3.hpp>

// RAII auto-pop (preferred)
void compute() {
    nvtx3::scoped_range r{"compute"};
    // ...
}

// With domain (namespacing)
struct MyApp { static constexpr char const* name{"MyApp"}; };
void hot() {
    nvtx3::scoped_range_in<MyApp> r{"hot_region"};
    // ...
}

// Push/pop (legacy style; per-thread stack-shaped)
nvtxRangePushA("phase1");
do_phase1();
nvtxRangePop();

// Start/end (handle-based; can cross threads)
nvtxRangeId_t id = nvtxRangeStartA("async_work");
// ... later ...
nvtxRangeEnd(id);
```

### Python usage

```python
import nvtx

with nvtx.annotate("epoch", color="blue"):
    for batch in loader:
        with nvtx.annotate("step", color="red"):
            train_one_step(batch)
```

PyTorch native:

```python
torch.cuda.nvtx.range_push("forward")
out = model(x)
torch.cuda.nvtx.range_pop()
```

### Integration with nsys / ncu

```bash
# nsys captures NVTX ranges by default with --trace=cuda,nvtx
nsys profile -t cuda,nvtx -o trace ./app

# Scope nsys collection to NVTX range
nsys profile --capture-range=nvtx --nvtx-capture='hot@MyApp' -o hot ./app

# ncu scope to NVTX range
ncu --nvtx-include 'hot' --set detailed -o ncu_out ./app
ncu --replay-mode range --nvtx-include 'hot' --set detailed -o range ./app
```

**Best practice:** annotate generously in production code. NVTX overhead is sub-microsecond; the readability win in `nsys-ui` is enormous. Many libraries (cuDNN, cuBLAS, NCCL, TensorRT-LLM) emit NVTX automatically — turn on with `--trace=nvtx`.

## DCGM and DCGM-Exporter

**What it is:** Data Center GPU Manager. Continuous low-overhead telemetry for fleet-wide GPU monitoring. **Distinct from Nsight** — DCGM samples the same hardware infrastructure but is designed for always-on Prometheus/Grafana export, not session-based deep dive.

**Primary URLs:**
- DCGM-Exporter docs: https://docs.nvidia.com/datacenter/dcgm/latest/gpu-telemetry/dcgm-exporter.html
- Repo: https://github.com/NVIDIA/dcgm-exporter
- API field IDs: https://docs.nvidia.com/datacenter/dcgm/latest/dcgm-api/dcgm-api-field-ids.html

### Deployment

```bash
# Standalone (bare-metal)
sudo apt install datacenter-gpu-manager
sudo systemctl enable nvidia-dcgm
sudo systemctl start nvidia-dcgm

# DCGM-Exporter for Prometheus (Kubernetes)
helm install dcgm-exporter nvidia/dcgm-exporter

# Verify on port 9400
curl http://localhost:9400/metrics | head -50
```

### Key metrics (DCGM_FI_PROF_*)

| Metric | Meaning |
|---|---|
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | Graphics/compute engine active ratio |
| `DCGM_FI_PROF_SM_ACTIVE` | Fraction of cycles SM has ≥1 warp resident |
| `DCGM_FI_PROF_SM_OCCUPANCY` | Ratio of warps resident on SM (achieved occupancy) |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | Ratio of cycles HMMA/Tensor pipe is active |
| `DCGM_FI_PROF_DRAM_ACTIVE` | DRAM interface active ratio |
| `DCGM_FI_PROF_PCIE_TX_BYTES` / `_RX_BYTES` | PCIe throughput |
| `DCGM_FI_PROF_NVLINK_TX_BYTES` / `_RX_BYTES` | NVLink throughput |
| `DCGM_FI_DEV_GPU_UTIL` | Coarse GPU utilization (legacy) |
| `DCGM_FI_DEV_FB_USED` | Frame buffer (HBM) used MB |
| `DCGM_FI_DEV_SM_CLOCK`, `_MEM_CLOCK` | Current clocks |
| `DCGM_FI_DEV_GPU_TEMP`, `_MEMORY_TEMP` | Temperatures |
| `DCGM_FI_DEV_POWER_USAGE` | Watts |

### Hardware multiplexing constraint

> "Some metrics require multiple passes ... due to hardware limitations on the GPUs, only certain groups of metrics can be read together. For example, SM Activity and SM Occupancy cannot be collected together with Tensor Utilization on V100 but can be done on T4."
> — NVIDIA DCGM docs

DCGM rotates metric groups; achieved sample rate per metric depends on group rotation. The `DCGM_FI_PROF_*` family is grouped — read the DCGM docs for the matrix per arch.

### Conflict with Nsight Systems

DCGM and `nsys --gpu-metrics-devices` compete for the same hardware sampling infrastructure. Symptom of conflict: `nsys` reports "Some GPUs are not supported" or shows empty metric tracks ([forum 294781](https://forums.developer.nvidia.com/t/issue-with-gpu-metrics-collection-for-nvidia-a100-on-nsight-systems/294781)).

**Fix:** tear down DCGM **DaemonSet**, not just service:

```bash
# Kubernetes
kubectl delete daemonset dcgm-exporter -n monitoring

# Bare-metal
sudo systemctl stop nvidia-dcgm
sudo systemctl stop dcgm-exporter
```

Then run `nsys`; restart DCGM after profiling.

### Known footguns

| Issue | Cause | Workaround |
|---|---|---|
| `Failed to load module 8 - dlopen(libdcgmmoduleprofiling.so.4)` ([dcgm-exporter #449](https://github.com/NVIDIA/dcgm-exporter/issues/449)) | Container missing `datacenter-gpu-manager-4-proprietary` package | Install proprietary package or use NVIDIA-provided exporter image |
| `DCGM_FI_PROF_*` metrics not collected on K80 ([dcgm-exporter #22](https://github.com/NVIDIA/dcgm-exporter/issues/22)) | K80 unsupported for profiling module | Use only basic device fields on K80 |
| Conflict with Nsight Systems | Shared sampling infrastructure | See above |

### Grafana dashboard

[NVIDIA-published](https://grafana.com/grafana/dashboards/12239) — drop-in for DCGM-Exporter on port 9400.

### When to use DCGM vs Nsight

| Need | Tool |
|---|---|
| Always-on fleet telemetry | DCGM + Prometheus + Grafana |
| Session-based deep dive | nsys / ncu |
| Multi-tenant Kubernetes (no admin permissions) | DCGM (no `NVreg_RestrictProfilingToAdminUsers` needed for `_PROF_` metrics in some configs — verify per cluster) |
| Per-kernel attribution | ncu (DCGM is per-GPU, not per-kernel) |
| Per-PID attribution | nvidia-smi pmon (limited); for full attribution use nsys --trace |

## Meta's Holistic Trace Analysis (HTA)

**What it is:** Multi-GPU trace synthesis tool. Ingests Kineto traces from N ranks, produces aggregated views and computes communication-computation overlap, critical paths, and frequent kernel patterns.

**Important:** HTA is **Meta-developed**, not NVIDIA. Open-sourced by Facebook AI / Meta AI Performance Engineering team. [Repo](https://github.com/facebookresearch/HolisticTraceAnalysis).

**Primary URLs:**
- Repo: https://github.com/facebookresearch/HolisticTraceAnalysis
- Docs: https://hta.readthedocs.io/
- PyTorch blog announce: https://pytorch.org/blog/trace-analysis-for-masses/ (2023-01, updated 2024-11)
- Tutorial: https://docs.pytorch.org/tutorials/beginner/hta_intro_tutorial.html

### What HTA does that nsys alone doesn't

1. **Multi-rank trace synthesis.** Ingests N Kineto traces (one per rank) and produces aggregated views.
2. **Temporal breakdown:** computation / communication / memory / idle time per rank, distribution across ranks (with error bars in the visualization).
3. **Communication-computation overlap formula:**
   > overlap = (time spent in computation while communicating) / (time spent in communication)
   > — directly from the HTA blog
   This is the metric that tells you whether your distributed training is well-overlapped.
4. **Frequent CUDA kernel patterns** — by operator, surfaces hot kernels in aggregate.
5. **Critical path analysis** ([critical_path_analysis.py](https://github.com/facebookresearch/HolisticTraceAnalysis/blob/main/hta/analyzers/critical_path_analysis.py)).
6. **Trace diff tool** for comparing runs.
7. **CUPTI Counter Analysis (experimental)** — for roofline.

### Usage

```bash
pip install HolisticTraceAnalysis

# Collect Kineto traces for all ranks (PyTorch native)
# Each rank exports to ./traces/rank_<N>.json

# Analyze
python -c "
from hta.trace_analysis import TraceAnalysis
t = TraceAnalysis(trace_dir='./traces')
t.get_temporal_breakdown()
t.get_comm_comp_overlap()
t.get_frequent_cuda_kernels()
"
```

### Known gotchas

| Issue | Cause | Workaround |
|---|---|---|
| CUPTI counter analysis demo produces empty traces ([HTA #146](https://github.com/facebookresearch/HolisticTraceAnalysis/issues/146)) | Specific CUPTI 18 + 3090 + Driver 12.2 combination | Use HTA without CUPTI counters; or use newer CUPTI |
| Last-step time series cuts off | Trace trim logic | Don't draw conclusions from trailing iteration |
| Nested user annotations attribute to lowest stack annotation only | Documented behavior | Re-annotate at the level you want aggregated |

### When to use HTA

- Multi-GPU / multi-node distributed training analysis where the question is "are we overlapping?"
- Aggregate analysis across many ranks (HTA: trivial; nsys-ui: opens N traces individually).
- Communication-computation overlap as a **quantitative metric**, not just a visual check.

For single-rank deep dive, `nsys-ui` is fine. HTA earns its install on multi-rank.

## Perfetto UI

**What it is:** Google's Chrome trace viewer / replacement for `chrome://tracing`. Web-based, hosted at https://ui.perfetto.dev/. Native support for Chrome trace JSON, Perfetto protobuf format, and ftrace.

### Sharing PyTorch profiler traces

```python
prof.export_chrome_trace("trace.json")
```

Then drag-and-drop `trace.json` into [Perfetto UI](https://ui.perfetto.dev/). Works in any modern browser.

### Sharing nsys traces

`.nsys-rep` is **not directly Perfetto-uploadable** (it's NVIDIA's proprietary SQLite-backed format). Conversion:

```bash
# Export to SQLite
nsys export --type sqlite -o trace.sqlite report.nsys-rep

# Use community nsys2json to convert to Chrome trace JSON
pip install nsys2json
python -m nsys2json --in trace.sqlite --out trace.json

# Upload trace.json to Perfetto
```

Note: `nsys2json` is a community tool ([chenyu-jiang/nsys2json](https://github.com/chenyu-jiang/nsys2json)), not officially supported by NVIDIA. Verify output before sharing for critical analysis.

### Sharing ncu reports

`.ncu-rep` has **no Chrome trace conversion path**. Sharing options:
- Send the `.ncu-rep` plus a screenshot of the relevant view.
- Export specific metric tables to CSV: `ncu --import report.ncu-rep --csv`.
- For high-level "where time goes," use `nsys` (which has a Perfetto path).

## cudaEvent timing — the honest wall-clock

When `ncu` distorts overlap and `nsys` is too coarse, fall back to `cudaEvent` timing **outside** any profiler:

```cpp
cudaEvent_t start, stop;
cudaEventCreate(&start);
cudaEventCreate(&stop);

cudaEventRecord(start);
// ... kernel launch ...
cudaEventRecord(stop);
cudaEventSynchronize(stop);

float ms;
cudaEventElapsedTime(&ms, start, stop);
printf("Kernel: %.3f ms\n", ms);
```

PyTorch:

```python
start = torch.cuda.Event(enable_timing=True)
end = torch.cuda.Event(enable_timing=True)
start.record()
# ... ops ...
end.record()
torch.cuda.synchronize()
print(f"Elapsed: {start.elapsed_time(end)} ms")
```

**The rule:** any wall-clock claim from `ncu` for an overlap-sensitive kernel (FA3, NCCL, CUTLASS Ping-Pong) must be cross-checked with `cudaEvent` timing. If they disagree, trust `cudaEvent`.

## Triton's profile hooks

**What's exposed (Triton 3.x):**

```bash
# See autotune decisions
TRITON_PRINT_AUTOTUNING=1 python script.py
# Prints: best config + total tuning time per kernel

# Cache directory (override default ~/.triton/cache/<base32-hash>/)
TRITON_CACHE_DIR=/tmp/triton-cache python script.py

# Kernel IR / SASS dumps
TRITON_KERNEL_DUMP=1 TRITON_DUMP_DIR=/tmp/dumps python script.py

# Force recompile (bypass cache — useful after env change)
TRITON_ALWAYS_COMPILE=1 python script.py

# MLIR / LLVM compile-pass timing
MLIR_ENABLE_TIMING=1 LLVM_ENABLE_TIMING=1 python script.py
```

**`tl.device_print(...)`** in kernels: device-side `printf`-style logging. Useful for debugging kernel-internal values during development.

### Triton autotune cache (NEW)

`@triton.autotune(..., cache_results=True)` writes timings to disk; subsequent runs skip re-tuning. Enable for production stacks; commit cache files for reproducibility.

### Known Triton footguns

| Issue | Cause | Workaround |
|---|---|---|
| `do_bench` underestimates 30% with default warmup ([triton #2306](https://github.com/triton-lang/triton/issues/2306)) | Default `warmup=25` too short | Set `warmup>=200`; or use `do_bench_cudagraph` |
| torch.compile picks wrong kernel first run, correct on second ([pytorch #164124](https://github.com/pytorch/pytorch/issues/164124)) | Cold inductor cache | Always run a throwaway iteration before measurement |
| Autotune cache invalidates on config edit ([triton #9822](https://github.com/triton-lang/triton/issues/9822)) | Adding/removing one config triggers full re-tune | Commit cache; pin config list |
| Mutating-input kernels misbehave under autotune ([triton #5339](https://github.com/triton-lang/triton/issues/5339), [#6547](https://github.com/triton-lang/triton/issues/6547)) | Autotune runs kernel multiple times for timing | Pass `restore_value=[...]`; or memoize inputs |
| `Proton` (Triton's ncu-lite) attributes to line 0 ([triton #8597](https://github.com/triton-lang/triton/issues/8597)) | Closed as "mostly correct" | Use `ncu` for line-level if Proton fails |

## TensorRT-LLM internal profiling

**What it is:** TensorRT-LLM's own profiling infrastructure. NVTX-annotated by default; supports detailed verbosity:

```bash
trtexec --profilingVerbosity=detailed --dumpProfile --useCudaGraph ./engine
```

For the inference-server side:
```python
# In TRT-LLM Python
from tensorrt_llm.runtime import GenerationSession
session = GenerationSession(...)
session.set_perf_callback(lambda step, latency: ...)
```

NVIDIA's recommended deep-dive: instrument the engine with NVTX, profile with `nsys`, escalate to `ncu` per-kernel as needed.

## vLLM / SGLang internal metrics

vLLM exposes Prometheus-format metrics on the OpenAI-compatible endpoint:

```
vllm_request_latency_seconds_bucket{...}
vllm_request_prompt_tokens
vllm_request_generation_tokens
vllm_gpu_cache_usage_perc
vllm_running_requests
vllm_pending_requests
```

For deeper analysis, use `--profile` flag (added 2024) which writes a `.nsys-rep` for each batched request.

SGLang has similar metrics + a built-in `bench_serving.py`.

## hyperfine — wall-clock A/B

For end-to-end "is the new version faster" — the reality check:

```bash
# Baseline vs optimized
hyperfine --warmup 3 './app_before' './app_after'

# Parameter sweep
hyperfine --warmup 3 './app --batch-size {bs}' -P bs 1 64

# JSON export for scripting
hyperfine --export-json bench.json --warmup 3 './app'
```

**Rule:** any optimization that shows as faster in `ncu`/PyTorch profiler but doesn't reduce `hyperfine` median is suspect. Counters lie; wall-clock doesn't.

## Quick-reference: task → tool

| Task | Tool | Command |
|---|---|---|
| PyTorch training profile | torch.profiler | `with profile(activities=[...]) as prof: ...` |
| Framework-level Python attribution | torch.profiler + Chrome trace | `prof.export_chrome_trace("trace.json")` → Perfetto |
| System-wide GPU timeline | nsys | `nsys profile -t cuda,nvtx,osrt --gpu-metrics-devices=all` |
| Multi-GPU comm-compute overlap | nsys per-rank → HTA | `nsys profile -o rank_%q{...}` then `TraceAnalysis(...)` |
| Per-kernel hardware counters | ncu | `ncu --set full -k regex:<name>` |
| Source-line stall attribution | ncu + lineinfo | `ncu --section SourceCounters --import-source yes` |
| Always-on fleet telemetry | DCGM + Prometheus | port 9400 + Grafana dashboard 12239 |
| Wall-clock A/B | cudaEvent / hyperfine | `cudaEventElapsedTime` or `hyperfine --warmup 3` |
| Sharing profiles cross-OS | Perfetto UI | `nsys export → nsys2json → Perfetto` or `prof.export_chrome_trace → Perfetto` |
| Triton kernel dev | Triton env vars | `TRITON_PRINT_AUTOTUNING=1`, `TRITON_KERNEL_DUMP=1` |
| TensorRT-LLM perf | trtexec + nsys | `trtexec --profilingVerbosity=detailed --dumpProfile` |
| vLLM serving metrics | Prometheus endpoint | `curl http://server/metrics \| grep vllm_` |
| Live monitoring | nvidia-smi dmon / nvtop / gpustat | `nvidia-smi dmon -s pucvmet` |

## The honest truth

For the common case — profile a PyTorch training or inference workload on Linux with NVIDIA GPU — the first tool to reach for is **`torch.profiler`**, not Nsight. Chrome trace + Perfetto UI gives you 80% of what most users need:
- Where iteration time goes (Python, CUDA, NCCL, idle).
- Which ops dispatch slowly.
- Memory allocation behavior.
- Multi-step schedule with built-in cycling.

Escalate to `nsys` when:
- You need GIL stalls / OS-runtime / NCCL detail visible.
- PyTorch profiler's framework attribution is too coarse.
- Multi-rank distributed training analysis (then chain into HTA).

Escalate to `ncu` when:
- You've identified the hot kernel and need per-section / per-counter deep dive.
- Tensor-core utilization, achieved DRAM bandwidth, stall-reason breakdown are the question.
- And the kernel is **not** overlap-sensitive (no NCCL, no FA3-style cross-warpgroup overlap), or you can use `--replay-mode range` with NVTX scoping.

For everything else — fleet telemetry (DCGM), multi-rank synthesis (HTA), wall-clock honesty (cudaEvent / hyperfine), profile sharing (Perfetto), Triton dev (`TRITON_*` env), serving metrics (Prometheus) — the ecosystem covers what Nsight doesn't.

`ncu` is a precision instrument for the per-kernel deep dive, not a first-reach. The fastest path to a correct answer is `torch.profiler` → `nsys` → `ncu`, in that order.

## References

### PyTorch profiler / Kineto
- [torch.profiler API docs](https://docs.pytorch.org/docs/stable/profiler)
- [Kineto repo](https://github.com/pytorch/kineto)
- [PyTorch profiler tutorial](https://docs.pytorch.org/tutorials/recipes/recipes/profiler_recipe.html)
- [PyTorch automated trace collection blog](https://pytorch.org/blog/automated-trace-collection/)

### NVTX
- [NVTX main page](https://nvidia.github.io/NVTX/)
- [NVTX repo](https://github.com/NVIDIA/NVTX)
- [NVIDIA blog — NVTX overview + Python](https://developer.nvidia.com/blog/nvidia-tools-extension-api-nvtx-annotation-tool-for-profiling-code-in-python-and-c-c/)

### DCGM
- [DCGM-Exporter docs](https://docs.nvidia.com/datacenter/dcgm/latest/gpu-telemetry/dcgm-exporter.html)
- [DCGM-Exporter repo](https://github.com/NVIDIA/dcgm-exporter)
- [DCGM API field IDs](https://docs.nvidia.com/datacenter/dcgm/latest/dcgm-api/dcgm-api-field-ids.html)
- [Grafana dashboard 12239](https://grafana.com/grafana/dashboards/12239)

### HTA
- [HTA repo](https://github.com/facebookresearch/HolisticTraceAnalysis)
- [HTA docs](https://hta.readthedocs.io/)
- [PyTorch blog announcing HTA](https://pytorch.org/blog/trace-analysis-for-masses/)
- [PyTorch HTA tutorial](https://docs.pytorch.org/tutorials/beginner/hta_intro_tutorial.html)

### Perfetto / Chrome trace / sharing
- [Perfetto UI](https://ui.perfetto.dev/)
- [Brendan Gregg — Flame Graphs](https://www.brendangregg.com/flamegraphs.html)
- [nsys2json (community)](https://github.com/chenyu-jiang/nsys2json)

### Triton
- [Triton repo](https://github.com/triton-lang/triton)
- [Triton autotune API](https://triton-lang.org/main/python-api/generated/triton.autotune.html)
- [Ian Barber — autotuning blog](https://ianbarber.blog/2025/05/04/autotuning-in-pytorch-triton/)
- [Red Hat — understanding Triton cache](https://next.redhat.com/2025/05/16/understanding-triton-cache-optimizing-gpu-kernel-compilation/)

### Practitioner sources
- [Mark Saroufim — GPU MODE lectures](https://github.com/gpu-mode/lectures)
- [Stas Bekman — ml-engineering](https://github.com/stas00/ml-engineering)
- [Michael Carilli — favorite nsys commands gist](https://gist.github.com/mcarilli/376821aa1a7182dfcf59928a7cde3223)
- [Horace He — Brrrr First Principles](https://horace.io/brrr_intro.html)

### Cross-tool comparisons
- [eunomia GPU profiling tools survey](https://eunomia.dev/blog/2025/04/21/gpu-profiling-under-the-hood-an-implementation-focused-survey-of-modern-accelerator-tracing-tools/)

### hyperfine
- [hyperfine — sharkdp/hyperfine](https://github.com/sharkdp/hyperfine)
