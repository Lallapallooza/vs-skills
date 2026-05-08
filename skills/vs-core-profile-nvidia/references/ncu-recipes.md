# Nsight Compute Recipe Library

Concrete, verified CLI invocations for `ncu` (Nsight Compute) on Linux. Each recipe names the goal, the command, and how to interpret the output. Flags correspond to **`ncu` 2026.1.1 (CUDA 13.2)** as documented at the [Nsight Compute CLI reference](https://docs.nvidia.com/nsight-compute/NsightComputeCli/index.html), [Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html), and [Customization Guide](https://docs.nvidia.com/nsight-compute/CustomizationGuide/index.html).

Older versions: most flags are stable across 2023.x → 2026.x; section names changed in 2024-2025 (older `WarpStateStatistics` → current `WarpStateStats`, etc.). Run `ncu --list-sections` on your installed version to verify section names.

## When NOT to use ncu

Read this before reaching for `ncu`. The tool fails or distorts in these cases:

1. **Cross-stream / cross-warpgroup overlap is the question.** `ncu` serializes via kernel replay as a measurement-overhead side effect. NCCL collectives, FA3 wgmma, CUTLASS Ping-Pong all get distorted 3–4× ([NCCL #466](https://github.com/NVIDIA/nccl/issues/466), [forum 272056](https://forums.developer.nvidia.com/t/why-does-ncu-perform-global-serialized-execution-for-all-current-kernels-during-kernel-replay/272056)). Use `nsys` + cudaEvents.
2. **MPS is enabled.** Not supported ([NCU 2025.4 known issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html)). Stop MPS for the profile.
3. **MIG slice is shared.** Concurrent workloads corrupt metrics. Isolate the slice.
4. **Confidential Computing on.** Counters disabled.
5. **vGPU without license.** Numbers silently degraded after 20 minutes.
6. **`ERR_NVGPUCTRPERM` and you can't change host modprobe.** Use DCGM or PyTorch profiler.

For everything else, `ncu` is the per-kernel deep-dive tool. Use it after `nsys` has named the kernel — never as the first reach.

## Pre-flight

```bash
# Version
ncu --version
# Check CUDA toolkit / driver compatibility (CUPTI is forward-only)
nvidia-smi | grep "Driver Version"
nvcc --version | grep release

# Profiler permission gate
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
# If 1, see install-troubleshoot.md §Permissions

# Available sections on this install
ncu --list-sections | head -30

# Available metric sets (predefined groups: SpeedOfLight, full, source, roofline, etc.)
ncu --list-sets

# Available metrics for the host's GPU
ncu --query-metrics --chip native | head

# Canary
ncu --section SpeedOfLight -o /tmp/canary /bin/true && echo "ncu ok"
```

## Top-level command structure

```
ncu [options] [-- <target> [args]]

Common subcommand-style usages:
  --list-sections, --list-sets, --query-metrics, --query-metrics-mode
  --import <report.ncu-rep>          # post-hoc analysis without re-running
  --export <baseline.ncu-bln>        # save as baseline
  --rule <name>                      # apply optimization-rule analysis (Hopper+)

GUI:
  ncu-ui [report.ncu-rep] [report.ncu-rep --baseline another.ncu-rep]
```

## Flag catalog

### Section / metric selection

| Flag | Meaning |
|---|---|
| `--section <name>` | Add named section to collection. Repeat for multiple. |
| `--section-folder <path>` | Custom section folder for project-specific section files. |
| `--set <set>` | Predefined set: `default`, `full`, `detailed`, `source`, `roofline`. |
| `--metrics <list>` | Comma-separated metric names. Supports prefixes: `regex:`, `group:`, `breakdown:`, `pmsampling:`. |
| `--query-metrics` | List metrics available for chip / current GPU. |
| `--query-metrics-mode {suffix,base,all}` | `suffix` = full names with `.avg`/`.sum`/etc.; `base` = base names only. |
| `--chip <name>` | Override chip for query (e.g., `gh100`, `gb100`, `ga100`). Useful offline. |
| `--list-sections`, `--list-sets`, `--list-rules` | Introspection. |

### Kernel filtering

| Flag | Meaning |
|---|---|
| `-k/--kernel-name <pattern>` | Exact match or `regex:<expr>`. Filter which kernels to profile. |
| `--launch-skip <N>` | Skip first N matching kernel launches. Useful to avoid warmup. |
| `--launch-count <N>` | Profile only N launches (after skip). |
| `--launch-skip-before-match <N>` | Skip N launches before applying name-match. |
| `--kernel-id <expr>` | Specify launch by ID format `[regex:]ctx-id:stream-id:kernel-id-or-name`. |
| `--nvtx`, `--nvtx-include`, `--nvtx-exclude` | Filter by NVTX range. Quantifiers `/` `[` `]` `*` `+`. |

### Replay control

| Flag | Meaning |
|---|---|
| `--replay-mode {kernel,application,range,app-range}` | Default `kernel`. See "Replay modes" below. |
| `--cache-control {all,none}` | `all` = flush caches between replays (most reproducible). `none` = no flush (better perf, less reproducible). |
| `--clock-control {base,boost,force-boost,none,reset}` | `base` (Volta+) for reproducibility. **Fails on MIG** — use `nvidia-smi -lgc` externally. `force-boost` is Ampere+ only. |

### Multi-process

| Flag | Meaning |
|---|---|
| `--target-processes {application-only,all}` | Default `application-only`. `all` profiles root + child processes. |
| `--communicator {none,shmem,tcp}` | `shmem` for concurrent NCCL kernels in same process tree was the headline NCU 2026.1 release-note addition; `tcp` is also accepted in the CLI value list (across processes), but the release-note prose only highlights `shmem` — verify `tcp` works on your install before depending on it. |
| `--lockstep-kernel-launch` | Force lockstep launch ordering across processes. Pairs with `--communicator`. |

### Output

| Flag | Meaning |
|---|---|
| `-o/--export <path>` | Output `.ncu-rep` (or `.ncu-repz` zstd-compressed). |
| `--baseline <path>` | Save as `.ncu-bln` baseline for later comparison. |
| `--import <path>` | Load existing report (post-hoc analysis without re-run). |
| `--csv` | Output as CSV. |
| `--page <name>` | When importing, show specific page (`details`, `source`, `raw`). |
| `--print-summary {none,per-gpu,per-kernel,total}` | Summary print level. |

### Source attribution

| Flag | Meaning |
|---|---|
| `--source-folders <list>` | Comma-separated paths to search recursively for source. |
| `--import-source {yes,no,unknown}` | Bake source into report. Requires `-lineinfo` build. |
| `--print-source` | Print source-correlated metrics inline. |

### Rules and optimization tips

| Flag | Meaning |
|---|---|
| `--rule <name>` | Apply optimization rule (warp stalls, occupancy, etc.) to identified kernel. |
| `--list-rules` | List available rules. |

### Debug / verbose

| Flag | Meaning |
|---|---|
| `--log-level {error,warning,info,trace}` | Verbose collector logs. |
| `--quiet` | Suppress routine messages. |
| `--print-details {none,kernel,all}` | Detail level in stdout summary. |

## Sections — what to collect when

Current section names (`ncu` 2026.x; older `*Statistics` → `*Stats`):

| Section | What it measures | When to use |
|---|---|---|
| `SpeedOfLight` | Throughput vs theoretical peak for compute and memory units. **Roofline subsections.** | Always start here. Single-section overview. |
| `MemoryWorkloadAnalysis` | L1/L2/DRAM throughput, hit/miss rates, memory-pipe utilization. **`_Chart` and `_Tables` subsections.** | Memory-bound suspect. |
| `ComputeWorkloadAnalysis` | Per-pipe utilization (FP, INT, FMA, ALU, Tensor, MIO, etc.). | Compute-bound suspect — see which pipe saturates. |
| `Occupancy` | Active warps / theoretical max. Per-block resource consumption (regs, smem). | Low-occupancy diagnosis (but see Volkov: low occupancy can be optimal). |
| `LaunchStats` | Block size, grid, registers/thread, dynamic smem, **`# Waves Per SM`**. | Wave-quantization diagnosis. |
| `SchedulerStats` | Issue rate, eligible warps, active warps. | Why warps not issuing? |
| `WarpStateStats` | Per-warp stall reasons (long_scoreboard, short_scoreboard, math_pipe_throttle, etc.). | Stall attribution. |
| `InstructionStats` | Per-instruction-type counts. Warp execution efficiency. | Instruction mix; divergence. |
| `SourceCounters` | PC-sampled stall reasons attributed to source lines. | Line-level attribution (needs `-lineinfo`). |
| `PmSampling` | PM Sampling time-series counters (Hopper+). | Time-series within a kernel. |
| `PmSampling_WarpStates` | Time-series warp stall reasons (Hopper+, GA10x+). | When stalls vary across kernel execution. |
| `Nvlink`, `Nvlink_Tables`, `Nvlink_Topology` | NVLink RX/TX bytes, topology. | Multi-GPU communication analysis. |
| `NumaAffinity` | NUMA node affinity. | Multi-socket / GH200 dual-die. |

Sets group sections:
- `default` — SpeedOfLight + LaunchStats + Occupancy.
- `full` — all sections (high overhead, many replays).
- `detailed` — SpeedOfLight + Memory + Compute + Scheduler + Warp + Launch + Occupancy + Instruction.
- `source` — adds SourceCounters (needs `-lineinfo`).
- `roofline` — SpeedOfLight with hierarchical roofline.

## Replay modes

The single most consequential flag for correctness:

| Mode | What it does | Pros | Cons |
|---|---|---|---|
| `kernel` (default) | Replay each kernel launch independently to collect metrics across passes. | Simplest. Works on any kernel. | **Serializes overlapping kernels** — destroys cross-stream / cross-warpgroup overlap (FA3, NCCL). |
| `application` | Relaunch the entire application for each pass. | Preserves overlap *within* application but kernel-to-kernel ordering may shift. Requires deterministic execution. | Long runs; data inputs must be identical across launches. |
| `range` | Replay a CUDA API range (NVTX-bracketed or cudaProfilerStart/Stop). Single pass per range. | Best for fused/overlapping kernels. PM Sampling supported. | Hopper+; range must be entered cleanly. |
| `app-range` | Combine `application` and `range` — relaunch app, profile a range. | For app-level reproducibility + range scope. | Same determinism cost as `application`. |

**Recommendation for overlap-sensitive kernels (FA3, NCCL, CUTLASS Ping-Pong):** `--replay-mode range` with NVTX brackets, or skip `ncu` entirely for the wall-clock claim and use `nsys` + cudaEvent.

## Recipes by goal

### 1. Speed-of-Light overview (start here)

```bash
# Lightweight — single section, tells you compute-vs-memory verdict
ncu --section SpeedOfLight \
    --launch-skip 5 --launch-count 3 \
    -o sol_out ./app

# Print summary
ncu --import sol_out.ncu-rep --csv | head -50
```

What to read:
- **SM Frequency Utilization, Memory Frequency Utilization** — base for everything else.
- **Compute throughput %** vs **Memory throughput %** — whichever is higher determines bottleneck regime.
- For Hopper+: roofline plot in `SpeedOfLight_RooflineChart` shows kernel position on the chart.

### 2. Full deep-dive on a known kernel

```bash
# After nsys named the kernel, full profile
ncu --set full \
    -k regex:flash_fwd \
    --launch-skip 5 --launch-count 3 \
    --import-source yes \
    --source-folders /path/to/src \
    -o full_out ./app

# Open in GUI
ncu-ui full_out.ncu-rep
```

`--set full` runs many sections — high overhead (multiple replays). For routine usage, prefer `--set detailed` or specific sections.

### 3. Roofline analysis (Hopper / Blackwell)

```bash
# Hierarchical roofline (L1, L2, DRAM diagonals)
ncu --set roofline \
    -k regex:<kernel> \
    -o roofline_out ./app

# View the roofline chart in GUI
ncu-ui roofline_out.ncu-rep
```

The roofline chart plots achieved performance vs the standard Williams roofline plus L1/L2/DRAM diagonals. AI < ridge → memory-bound; AI > ridge → compute-bound. Per-arch ridge points: see [roofline-and-mfu.md](roofline-and-mfu.md).

### 4. Memory deep-dive

```bash
ncu --section MemoryWorkloadAnalysis \
    --section MemoryWorkloadAnalysis_Tables \
    -k regex:<kernel> \
    -o mem_out ./app

# Specific raw metrics
ncu --metrics dram__throughput.avg.pct_of_peak_sustained_elapsed,\
dram__bytes_read.sum,\
dram__bytes_write.sum,\
lts__t_sector_hit_rate.pct,\
l1tex__t_sector_hit_rate.pct \
    -k regex:<kernel> \
    -o mem_metrics ./app
```

What to read: **Achieved DRAM throughput** vs peak (per [nvidia-arch-matrix.md](nvidia-arch-matrix.md): A100 SXM4 = 1.555 TB/s, H100 SXM5 = 3.35 TB/s, H200 = 4.8 TB/s, B200 = 7.7 TB/s). >70% achieved = memory-bound and saturated. <40% on a memory-bound kernel = something else is the bottleneck.

### 5. Tensor core utilization (per-arch)

```bash
# Hopper wgmma / Ampere HMMA / Ada FP8 / Blackwell tcgen05
# Generic family pattern — verify exact suffix per arch via --query-metrics
ncu --metrics regex:sm__inst_executed_pipe_tensor_op_.*\.avg\.pct_of_peak_sustained_active \
    -k regex:<kernel> \
    -o tc_metrics ./app

# Hopper-specific (after running --query-metrics --chip gh100)
ncu --metrics sm__inst_executed_pipe_tensor_op_hmma.avg.pct_of_peak_sustained_active,\
sm__inst_executed_pipe_tensor_op_imma.avg.pct_of_peak_sustained_active,\
sm__inst_executed_pipe_tensor_op_qmma.avg.pct_of_peak_sustained_active \
    -k regex:<kernel> \
    -o hopper_tc ./app
```

**Always cross-check with SASS:**

```bash
cuobjdump --dump-sass /path/to/binary | grep -E "HMMA|GMMA|UMMA|tcgen05" | head
```

The metric reports activity on the tensor pipe. The SASS reports what kind of MMA fired. **They can disagree** — see [flash-attention #1848](https://github.com/Dao-AILab/flash-attention/issues/1848) where FP8 kernels silently fell back to BF16 SASS but the tensor pipe metric still showed activity (because BF16 also uses the pipe). The metric proves "tensor cores fired"; the SASS proves "the right precision fired."

### 6. Source-correlated stall analysis

```bash
# Build with -lineinfo (NEVER -G)
nvcc -O3 -lineinfo my_kernel.cu -o my_app

# Profile with source attribution
ncu --section SourceCounters \
    --section SchedulerStats \
    --section WarpStateStats \
    --import-source yes \
    --source-folders $(pwd) \
    -k regex:<kernel> \
    -o src_out ./my_app

# Inspect line-level stalls in GUI
ncu-ui src_out.ncu-rep
# Switch to "Source" page; click a kernel; right pane shows per-source-line stall metrics
```

The "Source Counters" section is PC-sampled — see [pc-sampling-mechanics.md](pc-sampling-mechanics.md) for the precision contract. Sample period adjustable via the underlying CUPTI continuous-mode API.

### 7. Custom metric collection

```bash
# Cycles + retired ops + L2 hit rate + DRAM bytes
ncu --metrics gpc__cycles_elapsed.avg.per_second,\
sm__inst_executed.sum,\
lts__t_sector_hit_rate.pct,\
dram__bytes.sum \
    -k regex:<kernel> \
    -o custom ./app

# Regex-based metric selection
ncu --metrics regex:sm__warps_active.* \
    -k regex:<kernel> \
    -o warp_metrics ./app

# PM Sampling time-series (Hopper+ for warp states)
ncu --metrics pmsampling:smsp__warp_issue_stalled_long_scoreboard,\
pmsampling:smsp__warp_issue_stalled_short_scoreboard \
    -k regex:<kernel> \
    -o pm_stalls ./app
```

Metric naming follows `unit__counter[.aggregator[.qualifier]]` per the [Customization Guide](https://docs.nvidia.com/nsight-compute/CustomizationGuide/index.html). Use `--query-metrics` to discover.

### 8. NCCL kernel profiling (NCU 2026.1+)

```bash
# Pre-2026.1: ncu hangs on NCCL collectives. Skip and use nsys.
# NCU 2026.1+: --communicator coordinates concurrent kernels.

# Single-process tree (e.g., torchrun)
ncu --communicator shmem \
    --set detailed \
    --launch-skip 100 --launch-count 5 \
    -k regex:ncclKernel \
    -o nccl_out \
    torchrun --nproc_per_node=8 train.py

# Cross-process (separate processes, same node) — tcp is in CLI accepted values but release notes
# only highlighted shmem in 2026.1; canary `--communicator tcp` first before relying on it
ncu --communicator tcp \
    --lockstep-kernel-launch \
    --set detailed \
    -o nccl_tcp \
    mpirun -n 4 ./mpi_app
```

Even with `--communicator`, NCCL profiling is more reliably done with `nsys` for overlap analysis. Use `ncu --communicator` only when you specifically need per-kernel NCCL counters.

### 9. Compare runs (baseline + diff)

```bash
# Run baseline
ncu --set detailed -k regex:<kernel> -o baseline ./app

# Save as .ncu-bln (more compact, baseline-only)
ncu --baseline ./baseline.ncu-bln --set detailed -k regex:<kernel> ./app

# Run optimized
ncu --set detailed -k regex:<kernel> -o optimized ./app

# Compare in GUI
ncu-ui ./optimized.ncu-rep --baseline ./baseline.ncu-rep
# Or via CLI
ncu --import ./optimized.ncu-rep --baseline ./baseline.ncu-rep --csv > diff.csv
```

The GUI's "Compare" view shows per-metric delta with color-coding. The diff is per-kernel; use `--kernel-id` to compare specific launches across reports.

### 10. Range-replay for FA3-class fused kernels

```bash
# Wrap the hot range with NVTX in source
# nvtxRangePushA("hot_attn"); kernel<<<...>>>(...); nvtxRangePopA();

ncu --replay-mode range \
    --set detailed \
    --nvtx-include 'hot_attn' \
    --import-source yes \
    -o range_out ./app
```

Range-replay collects the entire NVTX-bracketed range as one unit, single pass per range, preserving overlap. **The standard fix for FA3 / CUTLASS Ping-Pong / cooperative-cluster kernels.**

### 11. Attach to a running PID (Hopper+ via CUPTI Range Profiler)

`ncu` does not have a true `--pid` attach (unlike nsys). Workarounds:

- Start the workload under `ncu` from the beginning with `--launch-skip` to skip warmup.
- Use NVTX with `--capture-range=cudaProfilerApi` semantics inside the application.
- For long-lived services, use the `--rule` (analysis) mode against a `.ncu-rep` produced earlier.

### 12. CUDA Graphs profiling

```bash
# Treat each graph instantiation as one unit (default)
ncu --graph-profiling graph --set detailed -o graphs ./app

# Per-node profiling (high overhead)
ncu --graph-profiling node --set detailed -o graph_nodes ./app
```

CUDA graphs' kernels are not separately replayable in `kernel` mode by default. Use `range` replay with NVTX scoping for graph-internal kernel analysis.

## The 5 operational metrics — exact ncu names

Operationalize gpu-ml-judgment §10 with current 2026.1 names:

| What | Metric | Section |
|---|---|---|
| SM occupancy | `sm__warps_active.avg.pct_of_peak_sustained_active` | Occupancy, SpeedOfLight |
| Achieved DRAM bandwidth | `dram__throughput.avg.pct_of_peak_sustained_elapsed` | MemoryWorkloadAnalysis, SpeedOfLight |
| Tensor core utilization (HMMA family) | `sm__inst_executed_pipe_tensor_op_hmma.avg.pct_of_peak_sustained_active` | ComputeWorkloadAnalysis |
| Warp execution efficiency | `smsp__thread_inst_executed_per_inst_executed.ratio` | InstructionStats, WarpStateStats |
| Stall reason (per category) | `smsp__warp_issue_stalled_<reason>.{avg,sum,pct_of_peak_sustained_active}` | WarpStateStats; PmSampling_WarpStates on Hopper+ |

For Hopper-specific tensor metrics: `sm__inst_executed_pipe_tensor_op_qmma.*` (FP8), and for Blackwell: `sm__inst_executed_pipe_tensor_op_*` family extended for FP4. **Always verify exact suffix on the live install** with:

```bash
ncu --query-metrics --chip native | grep tensor_op
```

## Stall reason taxonomy (18 categories)

From the Nsight Compute Profiling Guide; verbatim definitions are in [pc-sampling-mechanics.md](pc-sampling-mechanics.md). Quick decoder:

| Stall metric suffix | Means |
|---|---|
| `_long_scoreboard` | L1TEX-dependent wait — most commonly global memory loads (LDG/STG) but also texture/local/surface. Most common memory-bound symptom. |
| `_short_scoreboard` | Shared memory wait (LDS/STS) or MMA wait. |
| `_math_pipe_throttle` | Tensor cores saturated. **Good** stall — means you're compute-bound. |
| `_mio_throttle` | Shared memory queue full — bank conflicts or excess load. |
| `_lg_throttle` | Local/global pipeline saturation. |
| `_tex_throttle` | Texture unit throttle. |
| `_membar` | Memory barrier wait. |
| `_branch_resolving` | Branch target wait. |
| `_drain` | End-of-warp memory drain. |
| `_no_instruction` | Instruction fetch / icache miss. |
| `_imc_miss` | Constant cache miss. |
| `_dispatch_stall` | Dispatcher unable to issue. |
| `_not_selected` | Eligible but scheduler picked another warp. |
| `_selected` | Counted when warp issued (not really a stall). |
| `_sleeping` | All threads blocked/yielded. |
| `_warpgroup_arrive` | **Hopper-only** wgmma/cluster sync. |
| `_wait` | Generic fixed-latency wait. |
| `_misc` / `_barrier` | Catchall / block-level barrier. |

Fix-family decision:
- High `_long_scoreboard` → memory-bound. Reduce DRAM traffic; use TMA on Hopper; FlashAttention-style fusion.
- High `_short_scoreboard` → shared-memory-bound. Layout swizzling; reduce shared mem dependencies.
- High `_math_pipe_throttle` → already compute-bound. Use higher-throughput precision (BF16→FP8 on Hopper, FP8→FP4 on Blackwell).
- High `_mio_throttle` → bank conflicts. Pad strides or use swizzling.
- High `_warpgroup_arrive` (Hopper) → too many wgmma sync points. Increase pipeline depth with more producer-consumer warps.

## Custom NVTX-scoped profiling

NVTX ranges scope `ncu` collection precisely:

```bash
# Profile only inside NVTX range "hot"
ncu --nvtx-include 'hot' --set detailed -o nvtx_out ./app

# Multiple include patterns
ncu --nvtx-include 'attn/forward' \
    --nvtx-include 'mlp/forward' \
    --set detailed ./app

# Exclude specific ranges
ncu --nvtx-include 'training_step' \
    --nvtx-exclude 'optimizer' \
    --set detailed ./app
```

Quantifiers:
- `'hot'` — match exact range name.
- `'hot/sub'` — match nested range (`/` = nesting separator).
- `'/hot/'` — match range only at top level.
- `'hot*'` — wildcard suffix.

## Output format and sharing

`.ncu-rep` is proprietary — open in `ncu-ui` only. For sharing:

```bash
# Export to CSV for scripting / scripting analysis
ncu --import report.ncu-rep --csv > report.csv

# Compressed report
ncu --export report.ncu-repz ...   # zstd-compressed

# Baseline (compact, just baseline data)
ncu --baseline report.ncu-bln ...
```

There is **no native conversion** to Chrome trace JSON or pprof. To share with teammates without `ncu-ui`:
- Send the `.ncu-rep` plus a screenshot of the GUI view you want them to see.
- Export specific metric tables to CSV.
- For high-level "where time goes," use `nsys` (which exports to Perfetto-compatible JSON via SQLite path).

## Common errors and workarounds

| Error / symptom | Cause | Workaround |
|---|---|---|
| `==ERROR== ERR_NVGPUCTRPERM` | Profiler permission denied | See [install-troubleshoot.md](install-troubleshoot.md) §Permissions |
| `==ERROR== Profiling is not supported on device 0` (WSL on Win10) | WSL needs Win11 + driver 525+ | Boot native Linux |
| `==WARNING== Some metrics could not be queried` | Replay-mode mismatch or chip-unsupported metrics | Verify with `--query-metrics --chip <chipname>`; remove unsupported metrics |
| ncu hangs on NCCL kernel | Default kernel-replay can't handle mandatory-concurrent | `--communicator shmem` (NCU 2026.1+) or skip and use nsys |
| ncu reports kernel duration 3-4× slower than nsys | Kernel-replay serializes overlap | Use nsys for wall-clock; ncu for counters only |
| FA3 FP8 throughput looks low; tensor metric shows activity | SASS silent fallback to BF16 ([FA #1848](https://github.com/Dao-AILab/flash-attention/issues/1848)) | `cuobjdump --dump-sass`; verify `HMMA.F8` instructions present |
| Source view empty in ncu-ui | Compiled without `-lineinfo` | Recompile with `nvcc -O3 -lineinfo` |
| `--clock-control base` fails on MIG | NCU cannot lock clocks on MIG | `nvidia-smi -lgc base,boost` on parent device |
| Multi-process ncu loses child kernels | `--target-processes=application-only` | Use `--target-processes=all` |
| PM Sampling timeline distorted (initial samples) | Pre-2025.4.1 bug | Upgrade ncu; or discard first window |
| Range replay + multiple Green Contexts → aggregated counters | NCU 2025.4 known issue | Profile one Green Context at a time |
| MPS enabled → "Profiling with enabled MPS not supported" | Hardware constraint | Stop MPS daemon for profile |
| ncu duration vastly different from cudaEvent timing on overlapping kernels | Replay distortion | Trust cudaEvent for wall-clock |

## When metric values look impossible

If `ncu` reports something like 1800 TFLOPs of FP32 on H100 (30× theoretical max), the metric reading is wrong. Per Tri Dao (@tri_dao on X, Feb 2025): "One way to tell that the AI-written kernel is wrong without even reading the code is that it's way too fast — 1800 TFLOPS of FP32 on H100, 30× the theoretical max." Likely causes:

1. **Sparse vs dense confusion.** NVIDIA marketing reports sparse FLOPs (2:4 structured); dense is half. Verify the formula.
2. **Wrong precision attribution.** Tensor-pipe activity counts BF16 and FP8 the same; metric reads "100% activity" but precision differs.
3. **Replay distortion.** Wall-clock from `ncu` is unreliable on overlapping kernels.
4. **Sampling ratio scaled wrong.** Some metrics scale by `%enabled / %running`; if the multiplexing rotation didn't sample the kernel uniformly, the scaled value is misleading.

When in doubt: cross-check with `nsys` (wall-clock) and `cudaEvent` timing. If three sources disagree, trust `cudaEvent`; if `ncu` and `cudaEvent` agree but `nsys` disagrees, trust `ncu` for the per-kernel value but `nsys` for any cross-kernel claim.

## Quick-reference card

```bash
# I want to... | ...run this
Speed-of-Light overview               | ncu --section SpeedOfLight -o sol ./app
Full deep-dive on hot kernel          | ncu --set full -k regex:<name> --launch-skip 5 --launch-count 3 -o full ./app
Roofline                              | ncu --set roofline -k regex:<name> -o rl ./app
Memory deep-dive                      | ncu --section MemoryWorkloadAnalysis --section MemoryWorkloadAnalysis_Tables -k regex:<name> -o mem ./app
Tensor core check (with SASS verify)  | ncu --metrics regex:sm__inst_executed_pipe_tensor_op_.*\\.avg\\.pct_of_peak_sustained_active -k regex:<name> ./app && cuobjdump --dump-sass app | grep -E "HMMA|GMMA"
Source-correlated stalls              | ncu --section SourceCounters --section WarpStateStats --import-source yes -k regex:<name> -o src ./app
Custom metrics                        | ncu --metrics dram__throughput.avg.pct_of_peak_sustained_elapsed,sm__warps_active.avg.pct_of_peak_sustained_active -k regex:<name> -o m ./app
NCCL profile (NCU 2026.1+)            | ncu --communicator shmem --set detailed -k regex:nccl -o nccl ./app
Compare two runs                      | ncu-ui after.ncu-rep --baseline before.ncu-rep
Range replay (FA3-class)              | ncu --replay-mode range --nvtx-include 'hot' --set detailed -o range ./app
List sections / sets / metrics        | ncu --list-sections | ncu --list-sets | ncu --query-metrics --chip native
Import (post-hoc analysis)            | ncu --import report.ncu-rep --csv | ncu-ui report.ncu-rep
```

## References

- [Nsight Compute CLI Reference](https://docs.nvidia.com/nsight-compute/NsightComputeCli/index.html)
- [Nsight Compute Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
- [Nsight Compute Customization Guide (metric naming)](https://docs.nvidia.com/nsight-compute/CustomizationGuide/index.html)
- [Nsight Compute Release Notes](https://docs.nvidia.com/nsight-compute/ReleaseNotes/)
- [NCU 2025.4 Known Issues archive](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html)
- [Peak-Performance-Percentage Analysis Method (NVIDIA blog)](https://developer.nvidia.com/blog/the-peak-performance-analysis-method-for-optimizing-any-gpu-workload/)
- [Analysis-Driven Optimization Part 3 (NVIDIA blog)](https://developer.nvidia.com/blog/analysis-driven-optimization-finishing-the-analysis-with-nvidia-nsight-compute-part-3/)
- [Roofline Analysis with NVIDIA Nsight Compute (NVIDIA blog)](https://developer.nvidia.com/blog/accelerating-hpc-applications-with-nsight-compute-roofline-analysis/)
- [NCCL #466 — ncu hangs collectives](https://github.com/NVIDIA/nccl/issues/466)
- [Forum 272056 — ncu kernel replay reorders execution](https://forums.developer.nvidia.com/t/why-does-ncu-perform-global-serialized-execution-for-all-current-kernels-during-kernel-replay/272056)
- [flash-attention #1202 — measured vs theoretical FA FLOPs 3.77× discrepancy on Orin/RTX 4080, open](https://github.com/Dao-AILab/flash-attention/issues/1202)
- [flash-attention #1848 — FP8 silent fallback](https://github.com/Dao-AILab/flash-attention/issues/1848)
- [Mark Saroufim — GPU MODE lectures (CUDA profiling)](https://github.com/gpu-mode/lectures)
