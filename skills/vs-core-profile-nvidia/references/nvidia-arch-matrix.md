# NVIDIA Architecture Matrix for Profiling

Profiling results on NVIDIA GPUs are **arch-sensitive AND SKU-sensitive**: counter availability, peak FLOPs, HBM bandwidth, and even tensor-core instruction generation change across both axes. The most expensive trap is the SKU axis — H100 SXM5 and H100 PCIe share branding and `sm_90` compute capability but differ ~30% in compute and ~40% in HBM bandwidth. This reference is the authoritative "what changes?" table.

Currency: as-of CUDA 13.2 / Nsight Compute 2026.1.1 / driver 565+ (2026-04). Verify against `ncu --query-metrics --chip <chipname>` on the live host before quoting any specific metric availability — NVIDIA renames metrics between toolkit versions.

## Family / SM / kernel support

| Arch | Family | sm_ | Notable SKUs | Kernel support floor | Notes |
|---|---|---|---|---|---|
| Pascal | GP100 | sm_60 | P100 (datacenter), GP102/104 (RTX 10) | any modern | No tensor cores; no FP16 throughput parity. nvprof works (deprecated). |
| Volta | GV100 | sm_70 | V100 SXM2/PCIe, Titan V | 4.14+ | 1st-gen tensor cores (HMMA F16/F32). Independent thread scheduling. PC Sampling continuous-mode supported (cc 7.0+). |
| Turing | TU10x | sm_75 | T4, RTX 20 series, Quadro RTX | 4.20+ | 2nd-gen tensor cores (+ INT8/INT4). PM Sampling limited (no `GPU_TIME_INTERVAL`). |
| Ampere (datacenter) | GA100 | sm_80 | A100 40GB/80GB SXM/PCIe | 5.6+ | 3rd-gen TC (TF32, BF16, FP64 sparsity). MIG. PerfMon V2-equivalent counter set. |
| Ampere (consumer/workstation) | GA10x | sm_86 / sm_87 | A10, A30, A40, RTX 30 series, Jetson Orin (sm_87) | 5.6+ | Same TC family but smaller per-SM. PM Sampling `GPU_TIME_INTERVAL` enabled here onward. |
| Ada | AD10x | sm_89 | L4, L40, L40S, RTX 40 series | 5.18+ | 4th-gen TC (FP8 E4M3/E5M2). No TMA, no wgmma, no clusters (Hopper-only). |
| Hopper | GH100 | sm_90 / **sm_90a** | H100 SXM5, H100 PCIe, H100 NVL, H200 SXM | 5.18+ (basic), 6.2+ (perfmon), 6.7+ (full PM Sampling) | TMA, wgmma, thread block clusters, setmaxnreg, DPX, FP8, PM Sampling V2. **`sm_90a` enables arch-specific PTX (wgmma, TMA descriptors).** |
| Blackwell (datacenter) | GB100 | sm_100 / **sm_100a** | B100, B200, GB200 NVL | 6.10+ | 5th-gen TC (FP4/FP6/MXFP4/MXFP6), TMEM (`tcgen05`), 2-SM MMA, dual-die package. |
| Blackwell (consumer) | GB20x | sm_120 | RTX 5090, RTX 50 series | 6.12+ | Distinct from `sm_100`. Subset of datacenter Blackwell features; `tcgen05` available; FP4 inference. |

Detect on the live machine:

```bash
# Compute capability
nvidia-smi --query-gpu=name,compute_cap --format=csv
# OR via nvcc
nvcc --gpu-architecture=native --device-debug=0 -E -x cu /dev/null 2>&1 | grep -i sm_

# Architecture-specific sm_XXa variants (for wgmma, tcgen05)
ncu --query-metrics --chip ga100 2>/dev/null  # ga100 = sm_80
ncu --query-metrics --chip gh100 2>/dev/null  # gh100 = sm_90 / sm_90a
ncu --query-metrics --chip gb100 2>/dev/null  # gb100 = sm_100 / sm_100a
ncu --query-metrics --chip gb202 2>/dev/null  # consumer Blackwell sm_120
```

## SKU table — datacenter and prosumer GPUs

All numbers verified from NVIDIA datasheets + Lenovo product guides + arxiv microbenchmarking (HIGH confidence; sparse marked with *).

| SKU | Arch | sm_ | SMs | HBM | Bandwidth | L2 | BF16 dense | FP8 dense | FP4 dense | NVLink | TDP |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **P100 SXM2** | Pascal | sm_60 | 56 | 16 GB HBM2 | 720 GB/s | 4 MB | — | — | — | NVL1 (160 GB/s) | 300 W |
| **V100 SXM2** | Volta | sm_70 | 80 | 16/32 GB HBM2 | 900 GB/s | 6 MB | — (FP16 only) | — | — | NVL2 (300 GB/s) | 300 W |
| **T4** | Turing | sm_75 | 40 | 16 GB GDDR6 | 320 GB/s | 4 MB | — | — | — | None | 70 W |
| **A100 40GB SXM4** | Ampere | sm_80 | 108 | 40 GB HBM2 | 1.555 TB/s | 40 MB | 312 TFLOPS | — | — | NVL3 (600 GB/s) | 400 W |
| **A100 80GB SXM4** | Ampere | sm_80 | 108 | 80 GB HBM2e | 2.039 TB/s | 40 MB | 312 TFLOPS | — | — | NVL3 (600 GB/s) | 400 W |
| **A100 80GB PCIe** | Ampere | sm_80 | 108 | 80 GB HBM2e | 1.935 TB/s | 40 MB | 312 TFLOPS | — | — | NVL3 (600 GB/s, paired) | 300 W |
| **A10** | Ampere | sm_86 | 72 | 24 GB GDDR6 | 600 GB/s | 6 MB | 125 TFLOPS | — | — | None | 150 W |
| **L4** | Ada | sm_89 | 58 | 24 GB GDDR6 | 300 GB/s | 32+ MB | 121 TFLOPS | 242 TFLOPS | — | None | 72 W |
| **L40S** | Ada | sm_89 | 142 | 48 GB GDDR6 ECC | 864 GB/s | 96 MB | 362 TFLOPS | 733 TFLOPS | — | None | 350 W |
| **H100 PCIe** | Hopper | sm_90 / sm_90a | 114 | **80 GB HBM2e** ★ | **2.0 TB/s** ★ | 50 MB | **756 TFLOPS** | 1,513 TFLOPS | — | NVL4 (600 GB/s, 4-link) | 350 W |
| **H100 SXM5** | Hopper | sm_90 / sm_90a | 132 | 80 GB **HBM3** | **3.35 TB/s** | 50 MB | **989 TFLOPS** | 1,979 TFLOPS | — | NVL4 (900 GB/s) | 700 W |
| **H800 SXM** ◆ | Hopper | sm_90 / sm_90a | 132 | 80 GB HBM3 | 3.35 TB/s | 50 MB | 989 TFLOPS | 1,979 TFLOPS | — | NVL4 throttled (~400 GB/s) | 700 W |
| **H100 NVL** | Hopper | sm_90 / sm_90a | 132 | 94 GB HBM3 | 3.94 TB/s | 50 MB | 835 TFLOPS | 1,671 TFLOPS | — | NVL4 (600 GB/s) | 350-400 W |
| **H200 SXM** | Hopper | sm_90 / sm_90a | 132 | 141 GB **HBM3e** | 4.8 TB/s | 50 MB | 989 TFLOPS | 1,979 TFLOPS | — | NVL4 | 700 W |
| **B200 (HGX 1000W)** | Blackwell | sm_100 / sm_100a | dual-die | 180 GB HBM3e | 7.7 TB/s | 60 MB/die | **2,250 TFLOPS** | 4,500 TFLOPS | **9,000 TFLOPS** | NVL5 (1.8 TB/s) | 1000 W |
| **B200 (GB200 1200W)** | Blackwell | sm_100 / sm_100a | dual-die | 186 GB HBM3e | 8 TB/s | 60 MB/die | 2,500 TFLOPS | 5,000 TFLOPS | 10,000 TFLOPS | NVL5 (1.8 TB/s) | 1200 W |
| **RTX 5090** | Blackwell consumer | sm_120 | 170 | 32 GB GDDR7 | 1.79 TB/s | 128 MB | — (mixed reports) | yes | yes | None | 575 W |

★ = **VERIFIED H100 PCIe gotcha:** H100 PCIe is **HBM2e at 2 TB/s with 756 TFLOPS BF16 dense**, NOT HBM3 at 3.35 TB/s with 989 TFLOPS. The "H100 = HBM3 = 989 TFLOPS" mental model only applies to SXM5. Source: [NVIDIA Hopper architecture deep-dive](https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/).

◆ = **H800** is the export-restricted variant of H100 SXM5: identical compute (989 TFLOPS BF16 dense) and memory (HBM3, 3.35 TB/s), but NVLink bandwidth throttled to ~400 GB/s aggregate (vs H100 SXM5's 900 GB/s). Comm-bound multi-GPU workloads (tensor parallelism, large all-reduce) see a real perf cliff vs H100; per-GPU compute and memory profiles are identical. DeepSeek-V3 was trained on 2,048 H800s.

**Sparse note:** NVIDIA marketing typically headlines the *sparse* (2:4 structured) FLOPs number with an asterisk. The dense numbers above are halved. For practical roofline, use dense unless you have explicit sparsity in the model. FA3's "75% H100 utilization" is computed against the **989 TFLOPS dense** baseline (740/989 = 0.748), not the 1979 sparse — math forces this interpretation.

## Tensor-core generation per arch (instruction families)

Profilers must match the right instruction family or report zero tensor-core usage:

| Arch | Instruction family | SASS | Notes |
|---|---|---|---|
| Volta | 1st-gen | `HMMA.16816.F32.F16` (FP16→FP32) | First MMA. 4×4 matrix per core. |
| Turing | 2nd-gen | `HMMA`, `IMMA` (INT8/INT4) | Inference quant added. |
| Ampere | 3rd-gen | `HMMA`, `IMMA`, `BMMA` (binary), TF32 path | Sparsity 2:4. BF16 added. |
| Ada | 4th-gen | `HMMA` + FP8 path (E4M3/E5M2) | FP8 only. No TMA, no wgmma, no clusters. |
| Hopper | 4th-gen | **`GMMA.*` (warp-group MMA)** = SASS for `wgmma` PTX | Async; whole warpgroup cooperates. Stall reason: `Stall Warpgroup Arrive`. |
| Blackwell | 5th-gen | **`tcgen05.mma`** = "2-SM MMA"; FP4 (E2M1) + MXFP4/MXFP6 microscaling | TMEM-based — accumulators no longer thread-owned. |

**FP8 silent fallback footgun:** A kernel that compiles FP8 PTX may still emit `HMMA.F32.BF16` SASS if alignment, datatype mismatch, or library version isn't right. The kernel name is unreliable — only `cuobjdump --dump-sass` confirms the actual instructions. Documented in [Dao-AILab/flash-attention#1848](https://github.com/Dao-AILab/flash-attention/issues/1848): user saw `cutlass::float_e4m3_t` in kernel name but SASS only contained `HMMA.16816.F32.BF16`; throughput gain was bandwidth (half-byte storage), not FP8 compute.

## Compute capability and `sm_XXa` variants

`sm_XXa` ("a" = arch-specific) is a CUDA capability variant introduced for Hopper that allows kernels to use PTX features tied to a specific arch generation:

| sm_XXa | Enables |
|---|---|
| `sm_90a` | wgmma PTX, TMA descriptors, thread block cluster sync, setmaxnreg, DPX |
| `sm_100a` | tcgen05 PTX, 2-SM MMA, TMEM operations |

Compile with `-arch=sm_90a` (or `sm_100a`) for kernels that use these features. `-arch=sm_90` (no "a") is the portable subset. CUTLASS, cuBLASLt, FlashAttention-3 all require the "a" variants on Hopper. Profiler implication: certain ncu metrics only populate on `sm_XXa` builds.

## L2 cache scaling (ridge-point sensitivity)

L2 size determines whether a working set "fits in cache" — major impact on roofline:

| Arch | L2 |
|---|---|
| Volta V100 | 6 MB |
| Ampere A100 | 40 MB |
| Ada L40S | 96 MB |
| Hopper H100 | 50 MB |
| Hopper H200 | 50 MB (same as H100; only HBM differs) |
| Blackwell B200 | 60 MB per die (120 MB total dual-die) |
| Blackwell RTX 5090 | 128 MB |

For LLM serving: a 7B BF16 model is 14 GB — doesn't fit in any GPU L2. A 0.5B embedding matrix (1 GB BF16) fits in L40S's 96 MB only if quantized. The L2 metric to watch: `lts__t_sector_hit_rate.pct` (or section-level summary from MemoryWorkloadAnalysis).

## NVLink generations and topology

| Generation | Bandwidth/link | Per-GPU aggregate | Found on |
|---|---|---|---|
| NVLink 1 | 20 GB/s/dir × 4 links = 160 GB/s | 160 GB/s | P100 SXM |
| NVLink 2 | 25 GB/s/dir × 6 links = 300 GB/s | 300 GB/s | V100 SXM |
| NVLink 3 | 25 GB/s/dir × 12 links = 600 GB/s | 600 GB/s | A100 SXM/PCIe-paired |
| NVLink 4 | 25 GB/s/dir × 18 links = 900 GB/s | 900 GB/s | H100 SXM5; PCIe variant has 4-link/600 GB/s |
| NVLink 5 | 50 GB/s/dir × 18 links = 1.8 TB/s | 1.8 TB/s | B100/B200/GB200 |

NVSwitch generations (intra-rack):
- NVS-1 (Volta DGX-1): 8-GPU all-to-all
- NVS-2 (Ampere DGX A100): 8-GPU all-to-all 600 GB/s
- NVS-3 (Hopper DGX H100): 8-GPU 900 GB/s
- NVS-4 (Blackwell GB200 NVL72): 72-GPU rack, **130 TB/s aggregate** (NVL5+NVS-4)

ncu metric: `nvlrx__bytes`, `nvltx__bytes`, `nvlink__data_bytes_received`. Note from [NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html): NVLink metrics (`nvl*`) "are not supported on NVIDIA virtual GPUs (vGPUs)."

## PC Sampling and PM Sampling availability

(Detailed mechanics in [pc-sampling-mechanics.md](pc-sampling-mechanics.md). Capability summary here.)

| Arch | sm_ | Continuous PC Sampling (`cupti_pcsampling.h`) | PM Sampling | Warp-state via PM Sampling |
|---|---|---|---|---|
| Pascal | sm_60 | No | No | No |
| Volta | sm_70 | Yes | No | No |
| Turing | sm_75 | Yes | Limited (no `GPU_TIME_INTERVAL`) | No |
| Ampere A100 | sm_80 | Yes | Limited (`GPU_SYSCLK_INTERVAL` only) | No |
| Ampere GA10x (A10/A40/RTX 30) | sm_86 | Yes | Yes | Yes |
| Ada | sm_89 | Yes | Yes | Yes |
| Hopper | sm_90/90a | Yes (concurrent + PC Sampling same pass since CUDA 12.8) | Yes | Yes |
| Blackwell datacenter | sm_100/100a | Yes | Yes | Yes |
| Blackwell consumer | sm_120 | Yes | Yes | Yes |

**Activity-API PC Sampling** (the older path via `cupti_activity.h` + `CUpti_ActivityPCSampling*` records) was deprecated in CUDA 12.5 and **removed in CUDA 13.0**. Code that still uses it will fail to link against CUDA 13.x — migrate to `cupti_pcsampling.h`. Source: [CUPTI release notes](https://docs.nvidia.com/cupti/release-notes/release-notes.html).

## Hopper-specific features that change profiling

Hopper (sm_90/90a) adds features that require profiler-specific handling:

- **TMA (Tensor Memory Accelerator):** dedicated copy engine for 1D–5D async transfers between GMEM↔SMEM and SMEM↔SMEM within a cluster. Issued by a single thread; frees warps for compute. Stall reason on consumers waiting for TMA: `Stall Long Scoreboard` (memory pipeline) or `Stall Warpgroup Arrive` (cluster sync).
- **wgmma (warp-group MMA):** 4 warps cooperate as one warpgroup on a single MMA. Asynchronous via barriers. Tensor-core utilization metric is the same family (`sm__inst_executed_pipe_tensor_op_*`) but the SASS is `GMMA.*`.
- **Thread block clusters:** co-scheduled blocks across multiple SMs in same GPC. Up to 8 portable / 16 nonportable on H100. Distributed shared memory across cluster. Profiling: `ncu` LaunchStats reports cluster size; SchedulerStats shows cluster occupancy.
- **`setmaxnreg`:** runtime register-file repartitioning. FA3 producer warps `setmaxnreg.dec.sync 40` (40 registers, just TMA-issuing); consumer warps `setmaxnreg.inc.sync 232` (232 registers, full wgmma accumulators). Asymmetric register allocation enables more concurrent producer-consumer warps. Profiler note: occupancy metrics report aggregate; check `LaunchStats` for per-warp register count.
- **DPX (Dynamic Programming X):** Smith-Waterman, Floyd-Warshall acceleration. Distinct instruction family; metrics report under InstructionStats.
- **FP8 Tensor Cores (E4M3 + E5M2):** new ncu metrics `*_op_fp8_*`. **Verify with SASS — kernel name lies (see FA3 footgun above).**
- **PC Sampling continuous-mode + concurrent kernels in same pass:** since CUDA 12.8. Pre-12.8 you had to choose.

## Blackwell-specific features

Blackwell (sm_100/100a) adds:

- **5th-gen Tensor Cores with native FP4 (E2M1), FP6, MXFP4/MXFP6 microscaling.** New ncu metrics under `sm__inst_executed_pipe_tensor_op_*` family for FP4 specifically. ncu must be 2025.x+ to report Blackwell metrics.
- **Tensor Memory (TMEM):** new on-chip memory specifically for MMA accumulators. *"Threads no longer implicitly own the results of MMA operations and instead, TMEM is explicitly managed at the MMA scope from software, with `tcgen05` operations now issued by a single thread on behalf of the entire CTA, rather than at warp or warpgroup scope as in previous generations."* (semianalysis Blackwell teardown). Profiler implication: warp-state attribution for MMA-accumulator-related stalls is qualitatively different from Hopper. New stall reasons may appear under WarpStateStats.
- **`tcgen05.mma`:** new MMA instructions. Per [arxiv 2512.02189](https://arxiv.org/html/2512.02189v1) microbenchmarking, "2.9–11.2× lower single-instruction latency than Hopper for measured tile sizes."
- **2-SM MMA:** "a CTA pair collaboratively executes one MMA operation across 2 SMs." This breaks the assumption that one MMA = one SM; per-kernel SM occupancy reads differently.
- **Dual-die package:** B200 is two GB100 dies behaving as one logical GPU. ncu sees one device; per-die attribution requires NUMA-aware metrics (some NCU sections expose `--die` filters, verify on install).
- **`--g-tensor-memory-access-check` nvcc flag:** new for runtime TMEM access checking during development.

## "What changes when you change SKU/arch" — symptom→cause table

| Symptom after SKU/arch change | Likely cause | Fix |
|---|---|---|
| H100 BF16 numbers look 30% off vs A100 baseline | Using SXM5 number (989 TFLOPS) on PCIe SKU (756 TFLOPS dense) | Detect SKU via `nvidia-smi --query-gpu=name`; use the right peak |
| H100 PCIe HBM bandwidth shows ~2 TB/s, expected 3.35 | PCIe is **HBM2e**, not HBM3 | Treat H100 PCIe as a separate roofline; do not lump with SXM5 |
| `wgmma` metrics return zero on Ampere | wgmma is sm_90+ only | Use `HMMA` instruction metric on Ampere (3rd-gen TC) |
| FP4 metrics return zero on Hopper | FP4 is sm_100+ only | FP4 inference must run on Blackwell |
| `Stall Warpgroup Arrive` count is huge | Hopper warpgroup synchronization (wgmma waits) | Expected if using wgmma; minimize cross-warpgroup sync, batch wgmma issues |
| `Stall Long Scoreboard` huge on B200 | Memory wait — but TMEM stalls may also surface here on Blackwell | Cross-check with TMEM metrics; verify whether `tcgen05.mma` async paths are used |
| `cupti_activity.h` PC Sampling code links fail on CUDA 13 | Activity API removed CUDA 13.0 | Migrate to `cupti_pcsampling.h` |
| ncu metric naming changed (e.g., `WarpStateStatistics` → `WarpStateStats`) | ncu 2025+ shortened section names | Use `--list-sections` on installed ncu version |
| `--gpu-metrics-devices` works on H100 but not on Jetson Orin | Tegra/Jetson lack the data-center metrics path | Use `tegrastats` on Tegra; ncu only |
| `wgmma` kernel name but no FP8 throughput speedup | Silent fallback to BF16 SASS (FA3 #1848) | `cuobjdump --dump-sass <bin>`; grep for `HMMA.F8` or `HMMA.F32.BF16` |
| Blackwell consumer (sm_120) ncu queries return missing metrics | Consumer Blackwell ≠ datacenter Blackwell; subset feature set | Use `--chip gb202` for query; some `tcgen05` features absent |
| Multi-die B200 attribution off | One logical device but two physical dies | Use NUMA-aware metrics; `nvidia-smi topo -m` shows die layout |

## Quick generation probe

```bash
#!/usr/bin/env bash
# nvidia-gen.sh — print arch, key SKU caveats, and recommended profiler flags

if ! command -v nvidia-smi &>/dev/null; then
  echo "nvidia-smi not found"; exit 1
fi

read -r name cc <<<"$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader,nounits | head -1 | tr ',' ' ')"
echo "GPU: $name (compute cap $cc)"

case "$cc" in
  6.0|6.1) gen="Pascal"; tc="none" ;;
  7.0)     gen="Volta"; tc="1st gen (HMMA, FP16)" ;;
  7.5)     gen="Turing"; tc="2nd gen (+INT8/INT4)" ;;
  8.0)     gen="Ampere datacenter"; tc="3rd gen (TF32, BF16, sparsity)" ;;
  8.6|8.7) gen="Ampere consumer"; tc="3rd gen" ;;
  8.9)     gen="Ada"; tc="4th gen (FP8)" ;;
  9.0)     gen="Hopper"; tc="4th gen (FP8, wgmma, TMA)" ;;
  10.0)    gen="Blackwell datacenter"; tc="5th gen (FP4, tcgen05, TMEM)" ;;
  12.0)    gen="Blackwell consumer (sm_120)"; tc="5th gen subset" ;;
  *)       gen="Unknown ($cc)"; tc="?" ;;
esac
echo "Architecture: $gen"
echo "Tensor cores: $tc"

# SKU-specific caveat detection
case "$name" in
  *"H100 PCIe"*|*"H100 80GB PCIe"*)
    echo "⚠ H100 PCIe: HBM2e at 2.0 TB/s (NOT HBM3); BF16 dense = 756 TFLOPS (NOT 989)" ;;
  *"H100 SXM"*|*"H100 SXM5"*)
    echo "✓ H100 SXM5: HBM3 at 3.35 TB/s; BF16 dense = 989 TFLOPS" ;;
  *"H100 NVL"*)
    echo "✓ H100 NVL: HBM3 at 3.94 TB/s; BF16 dense = 835 TFLOPS" ;;
  *"H200"*)
    echo "✓ H200: HBM3e at 4.8 TB/s; same compute as H100 SXM5" ;;
  *"H800"*)
    echo "⚠ H800 (export-restricted): NVLink bandwidth-throttled vs H100. DeepSeek-V3 trained on these." ;;
  *"B200"*|*"GB200"*)
    echo "✓ Blackwell B200: HBM3e ~7.7-8 TB/s; FP4 native; dual-die package" ;;
  *"RTX 5090"*)
    echo "⚠ RTX 5090 (consumer Blackwell sm_120): subset of datacenter features; no NVLink" ;;
esac

# Profiler-relevant capability checks
echo ""
echo "Profiler capabilities:"
[ -e /proc/driver/nvidia/params ] && \
  echo "  RmProfilingAdminOnly: $(grep -oP 'RmProfilingAdminOnly: \K\d' /proc/driver/nvidia/params 2>/dev/null || echo 'unknown')"

# Activity-API PC Sampling availability
ncu_ver=$(ncu --version 2>/dev/null | head -1)
[ -n "$ncu_ver" ] && echo "  Nsight Compute: $ncu_ver"
nsys_ver=$(nsys --version 2>/dev/null | head -1)
[ -n "$nsys_ver" ] && echo "  Nsight Systems: $nsys_ver"

# MIG / MPS
mig=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | head -1)
[ -n "$mig" ] && [ "$mig" != "Disabled" ] && echo "  ⚠ MIG ENABLED: ncu cannot lock clocks; concurrent workloads corrupt metrics"
[ -e /tmp/nvidia-mps ] && echo "  ⚠ MPS server detected: ncu profiling NOT supported"

# Confidential Computing (Hopper+)
if nvidia-smi conf-compute -f 2>/dev/null | grep -qi "ENABLED"; then
  echo "  ⚠ Confidential Computing ON: profiling counters disabled (NCU 2025.4)"
fi
```

Save as `bin/nvidia-gen.sh`; run at session start.

## References

- [NVIDIA Hopper Architecture deep-dive](https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/) — H100 PCIe vs SXM5, TMA, wgmma, clusters
- [NVIDIA H100 datasheet](https://www.nvidia.com/content/dam/en-zz/Solutions/gtcs22/data-center/h100/PB-11133-001_v01.pdf)
- [NVIDIA H200 product page](https://www.nvidia.com/en-us/data-center/h200/)
- [NVIDIA Blackwell architecture page](https://www.nvidia.com/en-us/data-center/technologies/blackwell-architecture/)
- [NVIDIA A100 datasheet](https://www.nvidia.com/content/dam/en-zz/Solutions/Data-Center/a100/pdf/nvidia-a100-datasheet.pdf)
- [Lenovo H100 PCIe product guide (HBM2e confirmation)](https://lenovopress.lenovo.com/lp1732-thinksystem-nvidia-h100-pcie-gen5-gpu)
- [Lenovo B200 1000W product guide](https://lenovopress.lenovo.com/lp2226-thinksystem-nvidia-b200-180gb-1000w-gpu)
- [Glenn Lockwood — B200 spec compilation](https://glennklockwood.com/garden/processors/B200)
- [Microbenchmarking Blackwell (arxiv 2512.02189)](https://arxiv.org/html/2512.02189v1) — `tcgen05.mma` latency
- [Microbenchmarking Hopper (arxiv 2402.13499)](https://arxiv.org/abs/2402.13499) — wgmma SASS
- [Colfax — wgmma tutorial](https://research.colfax-intl.com/cutlass-tutorial-wgmma-hopper/)
- [SemiAnalysis — Dissecting Blackwell Tensor](https://newsletter.semianalysis.com/p/dissecting-nvidia-blackwell-tensor)
- [Volta Tuning Guide](https://docs.nvidia.com/cuda/volta-tuning-guide/index.html)
- [Hopper Tuning Guide](https://docs.nvidia.com/cuda/hopper-tuning-guide/index.html)
- [Ada Tuning Guide](https://docs.nvidia.com/cuda/ada-compatibility-guide/index.html)
- [CUPTI release notes (Activity-API deprecation)](https://docs.nvidia.com/cupti/release-notes/release-notes.html)
- [NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html)
- [Dao-AILab/flash-attention#1848 — FP8 silent fallback to BF16 SASS](https://github.com/Dao-AILab/flash-attention/issues/1848)
