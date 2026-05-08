---
name: vs-core-profile-nvidia
description: GPU profiling on NVIDIA hardware, Nsight-centric (Nsight Systems + Nsight Compute) with PyTorch profiler / Kineto / NVTX / CUPTI / DCGM / Meta HTA / Perfetto as first-class complements. Use when the user wants to profile, benchmark, or microarch-analyze CUDA kernels, ML training, or LLM inference on NVIDIA GPUs (Pascal through Blackwell). Also use when the user says "nsys", "ncu", "Nsight Systems", "Nsight Compute", "PC Sampling", "CUPTI", "Hopper TMA", "wgmma", "warp specialization", "tensor core utilization", "achieved DRAM bandwidth", "SM occupancy", "stall reasons", "NCCL profile", "NVLink topology", "MFU", "torch.profiler", "Kineto", "NVTX", "DCGM", "B200 profile", "FP8 profiling", "FP4 profiling", "roofline on H100", "wave quantization", "GPU idle time", "data loader bottleneck".
---

# NVIDIA GPU Profiling

Operational guide for profiling CUDA kernels, ML training, and LLM inference on NVIDIA GPUs (Pascal/Volta/Turing/Ampere/Ada/Hopper/Blackwell). Covers Nsight Systems (`nsys`), Nsight Compute (`ncu`), PyTorch profiler + Kineto, NVTX, CUPTI (Activity API + continuous-mode PC Sampling + PM Sampling + Range Profiler), DCGM, Meta's Holistic Trace Analysis, and Perfetto/Chrome-trace as the sharing format. References are arch-aware and CUDA-toolkit-version-pinned — copy-pasting a recipe across SKUs (H100 SXM5 → H100 PCIe) or toolkit versions silently produces wrong numbers.

**Currency:** as-of 2026-04. Pinned to CUDA 13.2 / Nsight Systems 2026.2 / Nsight Compute 2026.1.1 / driver 565+. Per-feature version pins live in the references; verify against your installed versions with `nsys --version`, `ncu --version`, `nvidia-smi`.

## Core principle: nsys before ncu, system-level before kernel-level

The single most common antipattern: starting with `ncu` on the kernel you suspect. Three reasons it's wrong:

1. **`ncu` kills overlap as a measurement-overhead side effect.** Default kernel-replay serializes overlapping streams to collect counters across multiple passes; NVIDIA staff describe it as "significant overhead when executing the application under the tool" and "the tool has to do work at the point where the kernel is launched" ([forum 272056](https://forums.developer.nvidia.com/t/why-does-ncu-perform-global-serialized-execution-for-all-current-kernels-during-kernel-replay/272056), felix_dt, Nov 2023). The practical consequence: kernels that depend on cross-stream / cross-warpgroup overlap (FlashAttention-3, NCCL collectives, CUTLASS Ping-Pong) are timed wrong by 3–4× under default `ncu`. Use `nsys` for any cross-stream timing claim, plus `cudaEvent` timing for honest wall-clock.
2. **The hot kernel is often not the bottleneck.** Data loader, Python dispatch, NCCL waits, cold cache — `nsys`'s system-level timeline shows GPU idle %, dispatch gaps, and which kernel actually dominates iteration time. Optimizing a kernel that's 8% of step time will not move end-to-end MFU.
3. **`ncu` cannot scope per-cgroup or per-MPS-client.** MIG slices have severe limits (no clock lock from `ncu`, any other workload corrupts metrics — [NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html)). MPS profiling is **not supported at all** by `ncu` (same source).

The decision table below encodes this. When in doubt, pick the tool whose specialization matches the question's specialization. `ncu` earns its install when you've identified the kernel via `nsys` and need per-section deep dive — not before.

## When to use this skill

Invoke on any profiling task targeting NVIDIA GPUs. Specifically:

- Hotspot attribution in a CUDA kernel, Triton kernel, or fused PyTorch op.
- Microarchitectural bottleneck categorization on a kernel (memory-bound vs compute-bound vs overhead-bound — [Horace He's taxonomy](https://horace.io/brrr_intro.html)).
- Achieved DRAM bandwidth, tensor-core utilization, SM occupancy, stall-reason attribution.
- NVLink/NCCL topology and overlap analysis.
- ML training MFU debugging (why is iteration time X but theoretical is Y?).
- LLM inference throughput debugging (TTFT, TPOT, decode bandwidth).
- Per-CUDA-device, per-MIG-instance, per-process profiling and the gotchas thereof.

**Do NOT use this skill for:**

- AMD ROCm GPU profiling — separate future skill (see also `vs-core-profile-amd` for the AMD CPU equivalent of this skill).
- Apple Silicon Metal / Intel GPU oneAPI — out of scope.
- GPU/ML engineering *judgment* (when occupancy is fine low, when FA loses to vanilla, when FP8 isn't free, AWQ vs GPTQ-Marlin) — that lives in `vs-core-_shared/prompts/language-specific/gpu-ml-judgment.md`. This skill is the tool-mechanics companion.
- General CPU profiling — use `vs-core-profile-amd` (AMD Zen) or generic `perf` from `gpu-ml-judgment.md`'s perf-judgment cross-references.

## Before doing anything: environment check

GPU profiling on Linux is unforgiving about driver/toolkit/permission state. Run these once per session:

```bash
# 1. What GPU(s) and what driver?
nvidia-smi
nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total,pcie.link.gen.current,pcie.link.width.current --format=csv
nvidia-smi topo -m   # NVLink/PCIe topology

# 2. CUDA toolkit and Nsight versions
nvcc --version
nsys --version       # nsys 2026.2 = CUDA 13.2; nsys 2024.5 = CUDA 12.6
ncu --version        # ncu 2026.1.1 = CUDA 13.2

# 3. Profiler permission state — the canonical "ERR_NVGPUCTRPERM" gate
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
# 0 = anyone can profile; 1 = root/CAP_SYS_ADMIN only (default since driver 418.43+ Linux / 419.17+ Windows).

# 4. Compute mode + persistence + lock state (for reproducibility)
nvidia-smi -q -d COMPUTE  # default | exclusive_process | prohibited
nvidia-smi -q -d PERSISTENCE_MODE
nvidia-smi -q -d CLOCK    # current vs locked clocks

# 5. MIG / MPS state (these break per-process attribution)
nvidia-smi -q -d MIG
ls /tmp/nvidia-mps 2>/dev/null && echo "MPS server running — ncu profiling NOT supported"

# 6. Container caps for CUPTI access (when running under Docker/k8s)
capsh --print | grep -i cap_sys_admin
# If absent: ncu inside container will fail with ERR_NVGPUCTRPERM despite host modprobe flag.

# 7. Symbol resolution check — kernel build flags
# nvcc:  -lineinfo (NEVER -G — disables opt, profile is meaningless)
# Triton: TRITON_CACHE_DIR populated for stable autotune
# PyTorch: torch.compile cache populated; first run is JIT cold

# 8. Confidential Computing mode (silently disables counters)
nvidia-smi conf-compute -f  # On = profiling NOT supported (NCU 2025.4 Known Issues).

# 9. Lock clocks for reproducible numbers (root)
sudo nvidia-smi -pm 1                        # persistence mode
sudo nvidia-smi -lgc <freq>,<freq>           # lock GPU clock to single value
# Hopper+: -lmc doesn't work; use --lock-memory-clocks-deferred instead.

# 10. Canary
nsys profile --trace=cuda --stats=true -o /tmp/canary /bin/true
ncu --section SpeedOfLight -o /tmp/canary_ncu --target-processes all /bin/true
echo $?
```

If the canary `ncu` invocation returns `==ERROR== ERR_NVGPUCTRPERM`, the modprobe flag is not in effect (or `--cap-add SYS_ADMIN` is missing from the container). See [install-troubleshoot.md](references/install-troubleshoot.md) §Permissions.

## Decision: which tool, when?

This is the central decision the skill must get right. The answer is almost never "ncu alone."

| Goal | First reach | Why | See |
|---|---|---|---|
| "Where is GPU time going?" (system-wide timeline, GPU idle %, dispatch gaps) | `nsys profile --trace=cuda,nvtx,cudnn,cublas,osrt -o out ./app` | System-level. Reveals data-loader, Python dispatch, NCCL waits before you waste time on a kernel that's 8% of the step. | [nsys-recipes.md](references/nsys-recipes.md) |
| "Is my data loader the bottleneck?" (PyTorch training) | `torch.profiler` with Chrome trace + `nsys profile --trace=cuda,osrt,nvtx,python-gil` | PyTorch profiler attributes to ops; nsys shows GIL stalls and DataLoader worker scheduling. | [ecosystem-complements.md](references/ecosystem-complements.md) |
| "Why is THIS specific kernel slow?" | `ncu --set full -k regex:<name> --launch-skip 5 --launch-count 3 -o out ./app` | Per-kernel hardware counters. Use only after `nsys` named the kernel. | [ncu-recipes.md](references/ncu-recipes.md) |
| "Memory-bound or compute-bound?" (per kernel) | `ncu --section SpeedOfLight --section MemoryWorkloadAnalysis -k regex:<name> -o out ./app` | SpeedOfLight gives the throughput vs roofline read; MemoryWorkloadAnalysis breaks down L1/L2/DRAM. | [roofline-and-mfu.md](references/roofline-and-mfu.md) |
| "Are tensor cores actually firing?" | `ncu --metrics sm__inst_executed_pipe_tensor_op_hmma.avg.pct_of_peak_sustained_active -k regex:<name> ./app` PLUS `cuobjdump --dump-sass` to confirm `HMMA`/`GMMA`/`UMMA` instructions present | The metric proves usage; SASS proves the *right* tensor type fired (FP8 vs BF16 silent fallback is a known FA3 footgun — [flash-attention#1848](https://github.com/Dao-AILab/flash-attention/issues/1848)). | [ncu-recipes.md](references/ncu-recipes.md), [nvidia-arch-matrix.md](references/nvidia-arch-matrix.md) |
| "Wave quantization?" (matmul-shape-induced underutilization) | `ncu --section LaunchStats --section SpeedOfLight ./app` then read `# Waves Per SM` | Fractional waves indicate quantization. Worked example: A100 N=1791 = 60 TFLOPs (1 wave); N=1793 = 43 TFLOPs (2 waves, 12 tiles in second). | [roofline-and-mfu.md](references/roofline-and-mfu.md) |
| "NCCL collective overlap?" | `nsys profile --trace=cuda,nvtx,nccl ./app` — and **NEVER** plain `ncu` | `ncu` serializes NCCL kernels by design ([NCCL #466](https://github.com/NVIDIA/nccl/issues/466), 5+ years confirmed); for `ncu`-on-NCCL use `--communicator shmem` (NCU 2026.1+) or skip and use nsys. | [ncu-recipes.md](references/ncu-recipes.md) |
| "Stall reason for a hot warp?" (line-level attribution) | `ncu --section SourceCounters -k regex:<name> --import-source yes ./app` (needs `-lineinfo`) | SourceCounters surfaces PC-sampled stall reasons attributed to source lines. | [pc-sampling-mechanics.md](references/pc-sampling-mechanics.md) |
| "Multi-GPU comm-compute overlap analysis" | `nsys` per-rank traces → Meta's [Holistic Trace Analysis (HTA)](https://github.com/facebookresearch/HolisticTraceAnalysis) | nsys alone shows per-rank; HTA synthesizes ranks and computes `overlap = compute_during_comm / comm_time`. | [ecosystem-complements.md](references/ecosystem-complements.md) |
| "Fleet-wide GPU utilization?" (Kubernetes / Prometheus) | DCGM-Exporter on port 9400 + `DCGM_FI_PROF_SM_ACTIVE`, `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`, `DCGM_FI_PROF_DRAM_ACTIVE` | Continuous low-overhead telemetry. Compete with nsys/ncu — tear down DCGM daemonsets before profiling. | [ecosystem-complements.md](references/ecosystem-complements.md) |
| "Compare two runs" (before/after optimization) | `ncu` baselines (`.ncu-bln`), or `nsys` recipes diff, or `hyperfine` for end-to-end wall-clock | `ncu` baselines are turnkey for ncu sessions; `hyperfine` is the honest end-to-end check. Counters that improve without moving wall-clock are artifacts. | [ncu-recipes.md](references/ncu-recipes.md), [ecosystem-complements.md](references/ecosystem-complements.md) |
| "Share profile with teammates on different OS" | `nsys export --type sqlite/json` then [Perfetto UI](https://ui.perfetto.dev/) for trace exploration; or `prof.export_chrome_trace()` from `torch.profiler` directly to Perfetto | `.nsys-rep` and `.ncu-rep` both need NVIDIA tooling to open; Chrome trace JSON works in any browser. | [ecosystem-complements.md](references/ecosystem-complements.md) |

**Default posture:** `nsys profile --trace=cuda,nvtx,cudnn,cublas,osrt --gpu-metrics-devices=all -o out ./app` first. `ncu --set full -k regex:<name>` only after `nsys` has named the kernel. PyTorch users start with `torch.profiler`, escalate to nsys when framework-level attribution is insufficient.

## Phase-structured workflow

### Phase 1: Understand the question (the regime)

Before profiling anything, name the regime — Horace He's taxonomy from [Making Deep Learning Go Brrrr From First Principles](https://horace.io/brrr_intro.html) (Mar 2022):

- **Compute-bound:** kernel saturates tensor cores or CUDA cores. AI > arch ridge point ([roofline-and-mfu.md](references/roofline-and-mfu.md) has the per-arch table).
- **Memory-bound:** achieved DRAM bandwidth near peak; AI < ridge. LLM decode is here for batch < 32.
- **Overhead-bound:** GPU idle % > 30%, dispatch gaps in `nsys`, Python/data-loader/NCCL dominates iteration time. Most "we're slow" reports for new ML engineers are this category.

The category determines the tool. "Profile the model" without a hypothesis wastes counter passes. If the user hasn't named a hypothesis, ask, or run `nsys profile` for 60 seconds and read the timeline before reaching for `ncu`.

### Phase 2: Build prerequisites

1. **Compile/build with profiling-friendly flags.** CUDA C++: `nvcc -O3 -lineinfo` (NEVER `-G` — disables optimization). Rust+CUDA: same. Triton: ensure `TRITON_CACHE_DIR` populated, autotune warm. PyTorch+`torch.compile`: do at least one warmup forward to populate `TORCHINDUCTOR_CACHE_DIR` (cold cache picks wrong autotuned kernel — [pytorch/pytorch#164124](https://github.com/pytorch/pytorch/issues/164124)).
2. **Enable profiler permissions.** `cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly`; if `1`, see [install-troubleshoot.md](references/install-troubleshoot.md) §Permissions.
3. **Pin clocks for reproducibility.** `sudo nvidia-smi -lgc base,boost`; persistence mode on.
4. **Tear down competing telemetry.** DCGM daemonsets ([NVIDIA forum 294781](https://forums.developer.nvidia.com/t/issue-with-gpu-metrics-collection-for-nvidia-a100-on-nsight-systems/294781)), `nvidia-smi dmon` polls — Nsight Systems and DCGM compete for the same hardware sampling infrastructure.
5. **Warmup.** 3–5 iterations or `hyperfine --warmup`. First iteration is cold cache and JIT-cold; do not measure it.
6. **Pin process to one GPU when relevant** (`CUDA_VISIBLE_DEVICES=0`) to avoid scheduler noise.

### Phase 3: Collect

Pick a recipe from [nsys-recipes.md](references/nsys-recipes.md) or [ncu-recipes.md](references/ncu-recipes.md) by Phase-1 hypothesis. Recipes to memorize:

```bash
# System-wide timeline (start here, always)
nsys profile --trace=cuda,nvtx,cudnn,cublas,osrt --gpu-metrics-devices=all \
  --capture-range=cudaProfilerApi -o nsys_out ./app

# PyTorch training timeline with framework overlay
nsys profile --trace=cuda,nvtx,osrt,python-gil --pytorch=autograd-shapes \
  --capture-range=cudaProfilerApi -o pt_train ./train.py

# Kernel deep dive (after nsys named the kernel)
ncu --set full -k regex:<kernel_name> --launch-skip 5 --launch-count 3 \
  --import-source yes -o ncu_out ./app

# Speed-of-Light only (lightweight overview across many kernels)
ncu --section SpeedOfLight --section LaunchStats -o ncu_sol ./app

# Roofline (Hopper/Ada/Blackwell)
ncu --set roofline -k regex:<kernel_name> -o ncu_roofline ./app

# Source-correlated stall analysis
ncu --section SourceCounters --section SchedulerStats \
  --import-source yes -k regex:<kernel_name> -o ncu_src ./app

# NCCL kernel profiling (NCU 2026.1+; older versions: skip and use nsys)
ncu --communicator shmem --set full ./mpi_job
```

### Phase 4: Interpret

Profile interpretation is where most beginners stall. Generation-aware:

- **The 5 metrics that cover 80% of diagnoses** (operationalize gpu-ml-judgment §10):
  - SM occupancy: `sm__warps_active.avg.pct_of_peak_sustained_active` (Occupancy section)
  - Achieved DRAM bandwidth: `dram__throughput.avg.pct_of_peak_sustained_elapsed` (MemoryWorkloadAnalysis)
  - Tensor-core utilization (per-arch — varies HMMA/wgmma/UMMA): see [nvidia-arch-matrix.md](references/nvidia-arch-matrix.md). Confirm with SASS, not metric alone.
  - Warp execution efficiency: `smsp__thread_inst_executed_per_inst_executed.ratio` (InstructionStats)
  - Stall reasons: `smsp__warp_issue_stalled_*` family (WarpStateStats; PmSampling_WarpStates on Hopper+ via PM Sampling)
- **Roofline numbers.** Per-arch peak FLOPs / HBM bandwidth in [roofline-and-mfu.md](references/roofline-and-mfu.md). Ridge point AI determines compute-vs-memory verdict. The single biggest mistake: applying H100 SXM5 numbers (989 TFLOPs BF16, 3.35 TB/s) to H100 PCIe (756 TFLOPs, 2.0 TB/s, **HBM2e not HBM3**) — confirmed [NVIDIA Hopper deep-dive](https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/).
- **Stall reasons.** 18 categories ([pc-sampling-mechanics.md](references/pc-sampling-mechanics.md) lists all verbatim). `Stall Long Scoreboard` = global memory wait. `Stall Short Scoreboard` = shared memory or MMA wait. `Stall Math Pipe Throttle` = tensor-core saturation (good kind of stall). `Stall Warpgroup Arrive` = Hopper-only wgmma/cluster sync.
- **Wave quantization.** Read `# Waves Per SM` in LaunchStats. Fractional values indicate the second wave wasted SMs ([Horace He A100 worked example](https://www.thonking.ai/p/what-shapes-do-matrix-multiplications): N=1791 → 60 TFLOPs / N=1793 → 43 TFLOPs, ~30% drop from one element).
- **NCCL profiles.** `nsys` shows the collective on its own stream; if there's no compute kernel concurrent above it, overlap isn't happening — the fix is scheduler/stream priority, not the collective itself.

### Phase 5: Verify + iterate

Performance claims need independent corroboration:

- Cross-check `ncu` per-kernel duration against `cudaEvent` timing outside the profiler. `ncu` distorts overlap; `cudaEvent` doesn't. If they disagree by >2× on an overlapping kernel, trust `cudaEvent`.
- Cross-check end-to-end with `hyperfine` (wall-clock, no profiler). Counter improvements that don't reduce wall-clock are artifacts.
- Profile on the same GPU SKU as production. H100 SXM5 → H100 PCIe is a 30% drop in BF16 peak and 40% drop in HBM bandwidth — large enough to invalidate conclusions.
- For ML training: end-to-end **MFU = observed_FLOPs / peak_FLOPs**, computed across the whole iteration. Llama 3 paper achieves 38–43% BF16 MFU on 16K H100 ([arXiv 2407.21783 §3.3.2](https://arxiv.org/abs/2407.21783)) — that's the production bar. <30% means an overhead-bound or memory-bound issue you haven't solved.

## When the skill should stop and escalate

Stop and surface to the user when:

1. **`ncu` canary fails with ERR_NVGPUCTRPERM** and host modprobe flag cannot be set (multi-tenant cluster, vGPU). Route to nsys + DCGM + cudaEvent timing — they don't need the same permission.
2. **MPS is enabled** ([NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html): "Profiling with enabled multi-process service (MPS) is not supported"). Stop the MPS daemon for the profile, or move to a non-MPS host.
3. **MIG slice is shared with other workloads** — metrics get corrupted. Isolate the slice or move to a dedicated MIG instance.
4. **Confidential Computing mode is on** — counters disabled as side-channel mitigation.
5. **Workload requires a scope `ncu` doesn't support** (per-cgroup, off-GPU/CPU-side timing, async I/O profiling). Route to PyTorch profiler / nsys / framework-internal metrics.
6. **Results disagree by >2× between `nsys` wall-clock and `ncu` duration on overlapping kernels.** This is not "tool disagreement" — it's `ncu`'s replay distorting overlap. Use `nsys` + cudaEvents for the wall-clock claim.
7. **The user asks for a metric that's generation-unsupported** (FP4 metrics on Hopper, wgmma metrics on Ampere, PC Sampling V2 on Pascal). Name the limitation; surface the closest available substitute.

## References (load as needed)

- [references/nsys-recipes.md](references/nsys-recipes.md) — Nsight Systems CLI flag catalog, recipes by goal (timeline, NCCL, MPI, PyTorch trace, cgroup-aware capture, attach mode), output formats, common errors.
- [references/ncu-recipes.md](references/ncu-recipes.md) — Nsight Compute CLI catalog, all sections, replay-mode tradeoffs (kernel/application/range/app-range), source-correlated profiling, custom metrics, FA/NCCL distortion workarounds.
- [references/pc-sampling-mechanics.md](references/pc-sampling-mechanics.md) — PC Sampling hardware contract (precision, scope, Activity-API vs continuous-mode), 18-entry stall-reason taxonomy, per-arch availability matrix, common mistakes.
- [references/nvidia-arch-matrix.md](references/nvidia-arch-matrix.md) — Pascal → Blackwell per-arch capability matrix: HBM/L2/SM, tensor core generation (HMMA/wgmma/UMMA), TMA/FP8/FP4 availability, NVLink generation, profiler-relevant differences, "what changes when you change SKUs" symptom→cause table, generation probe script.
- [references/roofline-and-mfu.md](references/roofline-and-mfu.md) — Roofline model on GPU, per-arch per-dtype peak FLOPs and bandwidth tables, ridge-point AI, MFU calculation methodology, ncu Roofline section, wave quantization detection, worked examples (compute-bound FA3, memory-bound LLM decode, overhead-bound data loader).
- [references/install-troubleshoot.md](references/install-troubleshoot.md) — Driver/CUDA/Nsight version compatibility, profiler permissions (NVreg_RestrictProfilingToAdminUsers), compute mode, persistence, lock clocks, MIG/MPS, container caps, cloud (AWS/GCP/Azure/WSL/Jetson), known errors → workarounds.
- [references/ecosystem-complements.md](references/ecosystem-complements.md) — PyTorch profiler + Kineto, NVTX (v3 header-only), DCGM + DCGM-Exporter (fleet telemetry), Meta HTA (multi-GPU trace synthesis), Perfetto for sharing, cudaEvent timing, Triton's profile hooks (TRITON_PRINT_AUTOTUNING etc.), TensorRT-LLM internal profiling, vLLM/SGLang metrics endpoints, "the honest truth" closer.

## Related skills / files

- `vs-core-_shared/prompts/language-specific/gpu-ml-judgment.md` — GPU/ML engineering judgment (when occupancy is fine low, FA losses, FP8 not free, AWQ vs GPTQ-Marlin). This skill is the *tool* companion to that *judgment*.
- `vs-core-_shared/prompts/language-specific/perf-judgment.md` — universal performance methodology (Coz, Mytkowicz, Kalibera-Jones, Roofline foundational). Cite inline when invoking a principle from it.
- `vs-core-profile-amd` — AMD CPU profiling (uProf-centric). Sister skill; same structure.
- `vs-core-debug` — when the GPU performance problem is a reproducible bug (hang, NaN, OOM mid-step). Use debug's reproduce/hypothesize/discriminate flow; invoke this skill for the profiling steps.
- `vs-core-research` — when you need deep technical research beyond what the references cover (e.g., a specific Nsight version regression, a recent kernel rewrite postmortem).
- `vs-core-implement` — when profiling feeds into a multi-file optimization implementation.

## Trigger phrases (routing hints)

"profile this on GPU", "run nsys", "use nsys profile", "Nsight Systems trace", "Nsight Compute deep dive", "ncu kernel report", "PC sampling", "stall reasons", "achieved DRAM bandwidth", "tensor core utilization", "is FP8 firing", "wgmma fired", "Hopper TMA profile", "warp specialization analysis", "is this memory-bound on H100", "memory-bound LLM decode", "compute-bound prefill", "GPU idle time", "data loader bottleneck", "PyTorch profiler", "torch.profiler", "Kineto trace", "NVTX range", "NCCL profile", "all-reduce overlap", "NVLink topology", "MFU", "model FLOPs utilization", "wave quantization", "roofline on H100", "roofline on B200", "Hopper roofline", "Blackwell FP4 profile", "DCGM metrics", "Holistic Trace Analysis", "HTA", "Perfetto UI", "Chrome trace", "ERR_NVGPUCTRPERM", "MIG profiling", "MPS profiling", "container can't profile", "WSL profile", "Jetson profile", "vGPU profile", "nvprof deprecated", "Visual Profiler dead".
