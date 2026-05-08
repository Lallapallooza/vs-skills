# PC Sampling Mechanics on NVIDIA

Currency: as-of 2026-04. CUDA 13.2; CUPTI continuous-mode `cupti_pcsampling.h` (CUDA 11.3+, Volta sm_70+). Activity-API path removed in CUDA 13.0.

NVIDIA's PC Sampling is the precise-attribution facility — analogous in role to AMD IBS or Intel PEBS, but **mechanistically different**. It is the feature most often misunderstood, mis-attributed in reports, and mis-interpreted by users of profilers that expose it. This reference is the load-bearing knowledge for correctly using and reading PC Sampling data on Volta through Blackwell.

## What PC Sampling is

> "CUPTI supports periodic sampling of the warp program counter and warp scheduler state. At a fixed interval of cycles, the sampler in each streaming multiprocessor (SM) selects an active warp and outputs the program counter and the warp scheduler state."
> — [NVIDIA CUPTI documentation](https://docs.nvidia.com/cupti/main/main.html)

**Key characteristics:**
- **Per-SM hardware sampler.** Each SM independently selects one active warp at the configured interval.
- **Statistical, not event-driven.** Unlike AMD IBS (which tags individual ops at dispatch with deterministic per-op metadata) or Intel PEBS (which records architectural state at the precise instruction triggering an event), NVIDIA PC Sampling fires at a **fixed cycle interval** and snapshots whichever warp is currently selected by the per-SM sampler.
- **Two modalities historically:**
  - **Activity-API PC Sampling** (`cupti_activity.h` + `CUpti_ActivityPCSampling*` records). Required kernel-replay serialization. **Deprecated CUDA 12.5; removed CUDA 13.0.**
  - **Continuous-mode PC Sampling** (`cupti_pcsampling.h`). CUDA 11.3+; Volta+ (cc 7.0+). Single-pass, no kernel replay needed.

The "V1/V2" terminology is community shorthand — NVIDIA never officially branded them with version numbers. This reference uses "Activity-API" (legacy) and "continuous-mode" (current).

## Sample contract: what gets recorded

For each sample, `CUpti_ActivityPCSampling3` records:

| Field | Meaning |
|---|---|
| `pc` | Program counter (instruction address within kernel). **Exact** for the sampled warp at sample time. |
| `stallReason` | One of 18 categories (taxonomy below). The reason this warp could not issue at this cycle. |
| `samples` | Number of times this PC was sampled with this stall reason within the aggregated record. |
| `latencySamples` | Subset of `samples` where no instruction was issued that cycle (cc 6.0+). |
| `correlationId` | Links to kernel launch. |
| `functionId` | Maps to function name. |

**Source:** [CUpti_ActivityPCSampling3 struct](https://docs.nvidia.com/cupti/api/structCUpti__ActivityPCSampling3.html).

> "Number of times the PC was sampled with the stallReason in the record. The same PC can be sampled with different stall reasons. These samples indicate that no instruction was issued in that cycle (valid for compute capability 6.0+)."

## Precision contract (the most important slide)

**PC is exact for the sampled cycle. Stall reason is exact for the sampled cycle. Aggregate counts are statistical.**

- The `pc` recorded is the actual current warp PC at sample time — hardware-precise. (Inferred from "outputs the program counter" with no "approximate" qualifier in the docs.)
- The `stallReason` is the warp scheduler state at sample time, exact for that one cycle.
- The `samples` aggregate over many sample windows is a statistical estimate of stall-cycle distribution. **Sample loss on overflow** is silent: if the sampling period is too short for the workload's instruction-rate, hardware buffers overflow and PC samples drop.

> "The software scratch buffer for raw PC counter data has a default size of 1 MB which can accommodate approximately 5500 PCs with all stall reasons ... if the sampling period is too short, the hardware buffer can overflow and drop PC samples."
> — eunomia tutorial citing CUPTI docs.

**Practical consequence:**
- Use PC Sampling to answer **where** questions: "which line / instruction is the top contributor to this stall reason?"
- Do NOT use PC Sampling to answer **how many** questions in absolute terms unless you can verify no sample loss (compare expected vs observed sample counts).

## Sampling period configuration

Continuous-mode PC Sampling exposes one configurable: sampling period (in cycles). Period = `2^N`, with `N ∈ [5, 31]`:

```c
// CUPTI continuous-mode API setup
CUpti_PCSamplingConfigurationInfo configEntry;
configEntry.attributeType = CUPTI_PC_SAMPLING_CONFIGURATION_ATTR_SAMPLING_PERIOD;
configEntry.attributeData.samplingPeriodData.samplingPeriod = 5;  // 2^5 = 32 cycles (highest rate)
// or = 31 → 2^31 cycles (lowest rate, ~2.1B cycles)
```

**Source:** [PC Sampling API](https://docs.nvidia.com/cupti/api/group__CUPTI__PCSAMPLING__API.html).

Default value: "CUPTI defined value based on number of SMs."

**Choosing a period:**
- Period too short (high rate) → buffer overflow, dropped samples, misleading aggregates.
- Period too long (low rate) → too few samples for statistical confidence.
- Empirical rule: aim for ~1000+ samples per kernel-of-interest. For a 1ms kernel at ~2 GHz cycle clock, that's ~2M cycles → period of `2^11 = 2048` (≈1000 samples) or smaller.

In Nsight Compute, the period is auto-tuned per the `--section SourceCounters` configuration — you rarely need to set it manually unless going through CUPTI directly.

## Activity-API vs continuous-mode (lifecycle)

The two PC Sampling APIs co-existed for years; understanding which is which matters for legacy code:

| Feature | Activity-API (legacy) | Continuous-mode (current) |
|---|---|---|
| Header | `cupti_activity.h` | `cupti_pcsampling.h` |
| Records | `CUpti_ActivityPCSampling`, `*PCSampling2`, `*PCSampling3` | `CUpti_PCSamplingPCData`, `CUpti_PCSamplingData` |
| Replay needed | **Yes** — kernel serialized | **No** — concurrent with execution |
| Min CUDA toolkit | Pre-11.3 | 11.3 |
| Hopper support | No (silently fails on H100) | Yes (since CUDA 11.8) |
| Concurrent kernels | Serialized | Single-pass since CUDA 12.8 |
| Status | **Deprecated CUDA 12.5; REMOVED CUDA 13.0** | Current and supported |

Source for deprecation/removal: [CUPTI release notes](https://docs.nvidia.com/cupti/release-notes/release-notes.html). Symptom of using legacy API on CUDA 13+: link failure (symbol not found) or runtime `CUPTI_ERROR_NOT_INITIALIZED`. Migrate to `cupti_pcsampling.h`.

## PM Sampling — separate, complementary feature

PM Sampling is a **distinct feature** from PC Sampling, often confused. Introduced for Ampere/Hopper, exposed in Nsight Compute 2024+:

> PM Sampling "periodically samples PM (performance monitor) counters into a hardware ring buffer."
> — [PM Sampling API](https://docs.nvidia.com/cupti/api/group__CUPTI__PM__SAMPLING__API.html)

- PC Sampling samples the **warp PC + scheduler state** at fixed cycle intervals.
- PM Sampling samples **performance counters** (selected per the configuration) at fixed time/cycle intervals into a hardware ring buffer.

| Trigger mode | Description | Availability |
|---|---|---|
| `GPU_SYSCLK_INTERVAL` | Sample every N system clock cycles. | All PM-supporting arches. |
| `GPU_TIME_INTERVAL` | Sample every N nanoseconds. | **Ampere GA10x and later only** (NOT GA100/A100, NOT Turing). |

Default warp-state sampling: enabled "on all GPUs GA10X and newer." [HIGH source: NVIDIA CUPTI docs.]

In Nsight Compute, the `PmSampling` and `PmSampling_WarpStates` sections expose PM Sampling time-series data. PC-sampled stall reasons appear under `WarpStateStats` (statistical) or `PmSampling_WarpStates` (time-series, Hopper+).

## Per-architecture availability matrix

Continuous-mode PC Sampling is the only path on supported hardware.

| Arch | sm_ | Continuous PC Sampling | PM Sampling | PM Sampling `GPU_TIME_INTERVAL` | Warp-state via PM Sampling |
|---|---|---|---|---|---|
| Pascal P100 | sm_60 | No | No | No | No |
| Volta V100 | sm_70 | **Yes** (since CUDA 11.3) | No | No | No |
| Turing T4 | sm_75 | Yes | Limited | No | No |
| Ampere A100 (GA100) | sm_80 | Yes | Limited | No | No |
| Ampere GA10x | sm_86 | Yes | Yes | **Yes** | Yes |
| Ada | sm_89 | Yes | Yes | Yes | Yes |
| Hopper H100/H200 | sm_90 / 90a | Yes (CUDA 11.8+) | Yes | Yes | Yes |
| Blackwell datacenter | sm_100 / 100a | Yes | Yes | Yes | Yes |
| Blackwell consumer | sm_120 | Yes | Yes | Yes | Yes |

**Hopper milestone:** CUDA 12.8 enables PC Sampling and concurrent-kernel tracing in the same pass. Pre-12.8 you had to choose.

## Stall reason taxonomy — 18 categories (verbatim)

Verbatim definitions from the [Nsight Compute Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html):

| Stall reason | Definition (verbatim) |
|---|---|
| **Stall Barrier** | "Warp was stalled waiting for sibling warps at a CTA barrier." |
| **Stall Branch Resolving** | "Warp was stalled waiting for a branch target to be computed, and the warp program counter to be updated." |
| **Stall Dispatch Stall** | "Warp was stalled waiting on a dispatch stall." |
| **Stall Drain** | "Warp was stalled after EXIT waiting for all outstanding memory operations to complete." |
| **Stall IMC Miss** | "Warp was stalled waiting for an immediate constant cache (IMC) miss." |
| **Stall LG Throttle** | "Warp was stalled waiting for the L1 instruction queue for local and global (LG) memory operations to be not full." |
| **Stall Long Scoreboard** | "Warp was stalled waiting for a scoreboard dependency on a L1TEX operation." (L1TEX dependency — most commonly global memory loads, also texture/local/surface; per NVIDIA staff [forum 230738](https://forums.developer.nvidia.com/t/long-scoreboard-stall-meanings/230738): "waiting for their data read to come back from memory.") |
| **Stall Math Pipe Throttle** | "Warp was stalled waiting for the execution pipe to be available." |
| **Stall MIO Throttle** | "Warp was stalled waiting for the MIO (memory input/output) instruction queue to be not full." |
| **Stall Misc** | "Warp was stalled for a miscellaneous hardware reason." |
| **Stall No Instructions** | "Warp was stalled waiting to be selected to fetch an instruction or waiting on an instruction cache miss." |
| **Stall Not Selected** | "Warp was stalled waiting for the micro scheduler to select the warp to issue." |
| **Stall Selected** | "Warp was selected by the micro scheduler and issued an instruction." (Technically not a stall — sampled in same channel.) |
| **Stall Short Scoreboard** | "Warp was stalled waiting for a scoreboard dependency on a MIO operation." (Shared memory dependencies are typical cause.) |
| **Stall Sleeping** | "Warp was stalled due to all threads in the warp being in the blocked, yielded, or sleep state." |
| **Stall Tex Throttle** | "Warp was stalled waiting for the L1 instruction queue for texture operations to be not full." |
| **Stall Wait** | "Warp was stalled waiting on a fixed latency execution dependency." |
| **Stall Warpgroup Arrive** | "Warp was stalled waiting on a WARPGROUP.ARRIVES or WARPGROUP.WAIT instruction." (**Hopper-only — wgmma/cluster sync.**) |

## Stall-reason → fix-family decision table

| Dominant stall | What it means | Fix family |
|---|---|---|
| `Long Scoreboard` (high) | Global memory load/store wait. Most common memory-bound symptom. | Reduce DRAM traffic; tile via shared memory; use TMA on Hopper; FlashAttention-style fusion. |
| `Short Scoreboard` (high) | Shared memory or MMA accumulator wait. | Reduce shared memory dependencies; layout swizzling; pipeline more wgmma issues. |
| `Math Pipe Throttle` (high) | Tensor cores or compute pipe saturated. **The good kind of stall.** | You're at compute peak. Use higher-throughput precision (BF16→FP8 Hopper, FP8→FP4 Blackwell). |
| `MIO Throttle` (high) | Shared memory queue full — bank conflicts or excess traffic. | Pad strides, use swizzling, reduce shared mem accesses per cycle. |
| `LG Throttle` (high) | Local/global pipeline queue full. | Reduce simultaneous global ops; use TMA for batch loads. |
| `Tex Throttle` (high) | Texture unit saturated. | Reduce texture lookups; switch to global loads with explicit caching. |
| `Branch Resolving` (high) | Indirect / unpredicted branches. | Branch-reduce; lookup tables; warp-coherent control flow. |
| `Drain` (high) | End-of-warp memory drain. | Smaller blocks; or accept (it's tail latency). |
| `No Instructions` (high) | Icache miss or fetch stall. | Reduce code footprint; align hot loops; smaller register-pressure-balanced kernels. |
| `Not Selected` (high) | Eligible warps but scheduler picked another. | Often noise. Compare to `Selected` ratio; if `Selected` low, you have a real issue elsewhere. |
| `Sleeping` (high) | Threads in `__nanosleep` or yielded. | Almost always intentional; verify the workload uses sleep correctly. |
| `Warpgroup Arrive` (high, Hopper) | wgmma sync points. | Increase pipeline depth (more producer-consumer warp groups). |
| `Membar` (high) | Memory barriers between phases. | Reduce barrier frequency; use async barriers. |
| `IMC Miss` (high) | Constant cache miss. | Move data out of constant memory if size > 8KB; or split into multiple constant arrays. |

## Scoping limitations

- **Per-CUDA-context / per-process scoping:** continuous-mode PC Sampling can be scoped to a specific CUDA context. ncu does this automatically per-launch.
- **Per-MIG-instance scoping:** Each MIG Compute Instance acts as a CUDA device. PC Sampling within a MIG instance is supported, **with constraints:**
  > "When profiling on a MIG instance, it is not possible to collect metrics from GPU units that are shared with other MIG instances. Collecting only metrics from GPU units that are exclusively owned by a shared Compute Instance is still possible."
  > — [Nsight Compute Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
- **MPS (Multi-Process Service):** ncu does not support profiling under MPS at all. CUPTI continuous-mode PC Sampling could in principle work per-context, but ncu's path is gated.
- **Cloud (vGPU, HVM):** vGPU mode often disables performance counters; PC Sampling unavailable. Bare-metal required.
- **Confidential Computing mode:** counters disabled; PC Sampling unavailable.

## Reading PC Sampling via ncu

```bash
# Compile with -lineinfo (NEVER -G — disables opt)
nvcc -O3 -lineinfo my_kernel.cu -o my_app

# Source-correlated profile
ncu --section SourceCounters \
    --section WarpStateStats \
    --import-source yes \
    --source-folders $(pwd) \
    -k regex:<kernel> \
    -o src_out ./my_app

# Open in GUI; navigate to Source page
ncu-ui src_out.ncu-rep
```

The "Source" page in `ncu-ui` displays per-source-line stall-reason counts. The "Statistics" tab shows aggregate stall-reason breakdown for the kernel as a whole.

For PM Sampling time-series of warp states (Hopper+):

```bash
ncu --section PmSampling --section PmSampling_WarpStates \
    -k regex:<kernel> \
    -o pm_out ./app
```

Time-series shows how stall reasons vary across kernel execution — useful when a kernel has phase changes (e.g., compute-heavy then memory-heavy).

## Reading PC Sampling via direct CUPTI

```c
// Continuous-mode PC Sampling skeleton
#include <cupti_pcsampling.h>

CUpti_PCSamplingConfigurationInfo configEntry[3];
// 1. Sampling period
configEntry[0].attributeType = CUPTI_PC_SAMPLING_CONFIGURATION_ATTR_SAMPLING_PERIOD;
configEntry[0].attributeData.samplingPeriodData.samplingPeriod = 11;  // 2^11 = 2048 cycles
// 2. Stall reason mask
configEntry[1].attributeType = CUPTI_PC_SAMPLING_CONFIGURATION_ATTR_STALL_REASON;
// ... configure which reasons to collect
// 3. Buffer size
configEntry[2].attributeType = CUPTI_PC_SAMPLING_CONFIGURATION_ATTR_SCRATCH_BUFFER_SIZE;
configEntry[2].attributeData.scratchBufferSize.size = 4 * 1024 * 1024;  // 4 MB

cuptiPCSamplingSetConfigurationAttribute(ctx, 3, configEntry);
cuptiPCSamplingEnable(ctx);
cuptiPCSamplingStart(ctx);
// ... kernel launch ...
cuptiPCSamplingStop(ctx);

CUpti_PCSamplingData data;
cuptiPCSamplingGetData(ctx, &data);
// process data.pPcData ...

cuptiPCSamplingDisable(ctx);
```

Reference implementations:
- NVIDIA samples: `/usr/local/cuda/extras/CUPTI/samples/pc_sampling_continuous_mode/`
- [eunomia CUPTI tutorial](https://eunomia.dev/others/cupti-tutorial/pc_sampling_continuous/)

## Common mistakes

1. **Quoting PC Sampling counts as exact totals.** They're statistical aggregates. Use to rank stall reasons, not to budget specific cycle counts.
2. **Comparing PC Sampling counts across runs without controlling sampling period.** Different periods produce different sample counts. Either use `pct_of_peak_sustained_active` ratios or fix the period.
3. **Using PC Sampling for short kernels (<100 µs).** Sample count too low for statistical confidence. Either extend the workload or aggregate many launches.
4. **Expecting per-thread attribution.** PC Sampling samples the warp, not threads — divergence is invisible.
5. **Trying to use Activity-API PC Sampling on CUDA 13.** Removed. Migrate to `cupti_pcsampling.h`.
6. **Conflating PC Sampling with PM Sampling.** PC Sampling = warp PC + stall reason. PM Sampling = performance counters. Different APIs, different use cases.
7. **Ignoring the architecture.** Pre-Volta lacks the modern stall taxonomy. Hopper adds `Warpgroup Arrive`. Blackwell adds TMEM-related stalls. Recipes that ignore arch produce silently wrong attribution.
8. **Sampling without `-lineinfo` build.** Source attribution will be empty. Recompile.
9. **Using PC Sampling under MPS or Confidential Computing.** Won't work. Disable those features for the profile.
10. **Treating `Stall Selected` as a stall.** It's the "warp issued an instruction" counter — actually the goal, not a problem.

## When NOT to use PC Sampling

- The workload is very short (<1ms) → sample count too low. Use `nsys` for timing + `ncu --section SchedulerStats` for aggregate.
- You need exact per-instruction execution counts → use traditional PMC counters (`smsp__inst_executed.sum`).
- You're hunting wrong-path or speculation cost → GPUs don't speculate the same way CPUs do; SchedulerStats `Eligible Warps Per Cycle` is closer.
- The kernel mostly stalls on `Math Pipe Throttle` → you already know you're compute-bound; switch precision or reduce work.
- MPS or Confidential Computing is on → not supported.
- vGPU without license → silently degraded.
- Per-thread attribution is needed → PC Sampling is warp-level only.

## When PC Sampling is uniquely useful

- **Line-level memory-stall attribution.** "Which load is causing the long-scoreboard stall?" → SourceCounters page in ncu-ui.
- **Verifying suspicious hot-loops.** `Stall Long Scoreboard` concentrated on one source line = that load is the bottleneck.
- **Hopper wgmma sync analysis.** `Stall Warpgroup Arrive` distribution shows where the producer-consumer pipeline is bottlenecking.
- **Distinguishing memory- from MMA-stall.** `Long Scoreboard` (memory) vs `Short Scoreboard` (MMA / shared) at the source-line level.

## References

- [NVIDIA CUPTI main documentation](https://docs.nvidia.com/cupti/main/main.html)
- [CUPTI PC Sampling API](https://docs.nvidia.com/cupti/api/group__CUPTI__PCSAMPLING__API.html)
- [CUPTI PM Sampling API](https://docs.nvidia.com/cupti/api/group__CUPTI__PM__SAMPLING__API.html)
- [CUpti_ActivityPCSampling3 struct](https://docs.nvidia.com/cupti/api/structCUpti__ActivityPCSampling3.html)
- [CUPTI release notes (Activity API deprecation)](https://docs.nvidia.com/cupti/release-notes/release-notes.html)
- [Nsight Compute Profiling Guide — Stall Reasons](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
- [eunomia CUPTI continuous-mode PC Sampling tutorial](https://eunomia.dev/others/cupti-tutorial/pc_sampling_continuous/)
- [DrGPU: A Top-Down Profiler for GPU Applications (ICPE 2023)](https://research.spec.org/icpe_proceedings/2023/proceedings/p43.pdf) — academic top-down using PC Sampling
- [Williams, Waterman, Patterson — Roofline (CACM 2009)](https://dl.acm.org/doi/10.1145/1498765.1498785) — methodology PC Sampling complements
- [forum 230738 — long_scoreboard meaning, NVIDIA staff response](https://forums.developer.nvidia.com/t/long-scoreboard-stall-meanings/230738)
