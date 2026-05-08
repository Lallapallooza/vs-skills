# Roofline and MFU on NVIDIA GPUs

Roofline + MFU (Model FLOPs Utilization) are the two methodologies that answer "is this kernel/training/inference at the limit, or leaving perf on the table?". They are the GPU equivalents of CPU TMA — except there is no clean GPU TMA, so Roofline + Speed-of-Light + DrGPU's stall-decomposition is the practitioner's stack.

This reference is the operational companion to `vs-core-_shared/prompts/language-specific/gpu-ml-judgment.md` §3 (memory hierarchy) and §16 (AI threshold). The judgment file argues *why* arithmetic intensity matters; this file gives you the *numbers* and the *exact ncu invocations* to read them.

Currency: as-of 2026-04. Per-arch peaks verified from NVIDIA datasheets + Lenovo product guides + arxiv microbenchmarking.

## The Roofline model (Williams 2009)

> Performance = min(Peak FLOPs/s, Peak Bandwidth × Arithmetic Intensity)

- **Arithmetic Intensity (AI):** total FLOPs / total bytes transferred (units: FLOPs/byte).
- **Ridge point AI** = Peak FLOPs/s ÷ Peak Bandwidth. Kernels with AI < ridge are memory-bound; AI > ridge are compute-bound.
- **Source:** Williams, Waterman, Patterson, "Roofline: an Insightful Visual Performance Model for Multicore Architectures," CACM 2009 ([dl.acm.org](https://dl.acm.org/doi/10.1145/1498765.1498785), [Berkeley PDF](https://people.eecs.berkeley.edu/~kubitron/cs252/handouts/papers/RooflineVyNoYellow.pdf)).

Two roofline shapes used in practice:

1. **Standard (DRAM-only):** one diagonal at slope = peak DRAM bandwidth.
2. **Hierarchical:** multiple diagonals — L1, L2, DRAM. Closest cache that doesn't bottleneck determines the kernel's actual ceiling. NVIDIA implements this in `ncu`'s `SpeedOfLight_HierarchicalDoubleRooflineChart` subsection.

## Per-arch peak FLOPs and bandwidth

All numbers verified from NVIDIA datasheets + cross-referenced with Lenovo product guides. **Dense values; sparse 2:4 = dense × 2.**

| GPU | HBM | Bandwidth | BF16 dense (TFLOPS) | FP8 dense | FP4 dense | TDP |
|---|---|---|---|---|---|---|
| **A100 40GB SXM4** | HBM2 | 1.555 TB/s | 312 | — | — | 400 W |
| **A100 80GB SXM4** | HBM2e | 2.039 TB/s | 312 | — | — | 400 W |
| **A100 80GB PCIe** | HBM2e | 1.935 TB/s | 312 | — | — | 300 W |
| **L40S** | GDDR6 ECC | 864 GB/s | 362 | 733 | — | 350 W |
| **H100 PCIe** ★ | **HBM2e** ★ | **2.0 TB/s** ★ | **756** ★ | 1,513 | — | 350 W |
| **H100 SXM5** | HBM3 | 3.35 TB/s | **989** | 1,979 | — | 700 W |
| **H100 NVL** | HBM3 | 3.94 TB/s | 835 | 1,671 | — | 350-400 W |
| **H200 SXM** | HBM3e | 4.8 TB/s | 989 | 1,979 | — | 700 W |
| **B200 (HGX 1000W)** | HBM3e | 7.7 TB/s | **2,250** | 4,500 | **9,000** | 1000 W |
| **B200 (GB200 1200W)** | HBM3e | 8.0 TB/s | 2,500 | 5,000 | 10,000 | 1200 W |

★ = **The H100 PCIe trap.** The "H100 = 989 TFLOPS BF16, 3.35 TB/s HBM3" mental model **only applies to SXM5**. PCIe is 30% lower compute and 40% lower bandwidth and uses HBM2e (not HBM3). Source: [NVIDIA Hopper deep-dive](https://developer.nvidia.com/blog/nvidia-hopper-architecture-in-depth/), [Lenovo H100 PCIe product guide](https://lenovopress.lenovo.com/lp1732-thinksystem-nvidia-h100-pcie-gen5-gpu).

## Arithmetic Intensity threshold (ridge point)

Computed as Peak Dense FLOPs ÷ Peak Bandwidth, units FLOPs/byte:

| GPU | dtype | Peak (TFLOPS) | BW (TB/s) | **Ridge AI (FLOPs/byte)** |
|---|---|---|---|---|
| A100 80GB SXM4 | BF16 | 312 | 2.039 | **153** |
| A100 80GB PCIe | BF16 | 312 | 1.935 | 161 |
| H100 SXM5 | BF16 | 989 | 3.35 | **295** |
| H100 SXM5 | FP8 | 1,979 | 3.35 | **591** |
| H100 PCIe | BF16 | 756 | 2.0 | 378 |
| H100 PCIe | FP8 | 1,513 | 2.0 | 757 |
| H200 SXM | BF16 | 989 | 4.8 | **206** |
| H200 SXM | FP8 | 1,979 | 4.8 | 412 |
| B200 (1000W) | BF16 | 2,250 | 7.7 | **292** |
| B200 (1000W) | FP8 | 4,500 | 7.7 | 584 |
| B200 (1000W) | FP4 | 9,000 | 7.7 | **1,168** |

Verifies gpu-ml-judgment §16's H100 BF16 = 295 and FP8 = 591 numbers. The H200 ridge drops to 206 because the bigger HBM3e bandwidth raises the memory ceiling — H200 makes *more* of the workload memory-bound relative to compute. This is the architectural intent: H200 was sold as a memory-bandwidth upgrade over H100.

**Important:** these are *theoretical ceilings*. Real kernels rarely hit 100% of either peak; achieved AI for "memory-bound" workloads is often ~50–70% of peak bandwidth, and "compute-bound" workloads typically achieve 60–90% of peak FLOPs.

## Reading the roofline in `ncu`

```bash
# Roofline section (Hopper / Blackwell with full hierarchy)
ncu --set roofline -k regex:<kernel> -o roofline_out ./app

# View in GUI
ncu-ui roofline_out.ncu-rep
```

The GUI's "Speed of Light" page shows:
- **`SpeedOfLight_RooflineChart`** — single-diagonal DRAM roofline.
- **`SpeedOfLight_HierarchicalDoubleRooflineChart`** — L1 + L2 + DRAM diagonals. Kernel's plot point falls below whichever diagonal is the bottleneck.

Underlying metrics that compose the roofline:
- FLOPs by precision: `sm__sass_thread_inst_executed_op_*` (FP32, FP16, BF16, FP8, etc.)
- DRAM bytes: `dram__bytes.sum`
- L2 bytes: `lts__t_bytes.sum`
- L1 bytes: `l1tex__t_bytes.sum`

ncu computes per-kernel AI as `total_FLOPs / bytes_at_each_memory_level`. The point's position relative to each diagonal indicates which memory level is the ceiling.

**Source:** [NVIDIA blog on Roofline Analysis with Nsight Compute](https://developer.nvidia.com/blog/accelerating-hpc-applications-with-nsight-compute-roofline-analysis/) (NVIDIA + LBNL/Berkeley collaboration).

## Speed of Light interpretation (NVIDIA's "almost top-down")

NVIDIA's [Peak-Performance-Percentage Analysis Method](https://developer.nvidia.com/blog/the-peak-performance-analysis-method-for-optimizing-any-gpu-workload/) is the closest GPU equivalent of CPU TMA, though not formally hierarchical. The decision tree:

| Top SOL % | Verdict |
|---|---|
| > 80% | Kernel is at the limit. **Reduce work** (algorithmic change) — don't try to make this kernel faster. |
| 60–80% | Both compute and memory are well-utilized, but neither saturated. Look for specific stalls (WarpStateStats) or reduce work overhead. |
| < 60% | Underutilized. Increase throughput — bigger blocks, more concurrent work, fewer dependencies. |

The ratio measured: `sm__throughput.avg.pct_of_peak_sustained_elapsed` and `gpu__compute_memory_throughput.avg.pct_of_peak_sustained_elapsed`.

For the Horace He taxonomy translation:
- **Compute-bound:** Compute SOL > 60%, Memory SOL < 50%.
- **Memory-bound:** Memory SOL > 60%, Compute SOL < 30%.
- **Overhead-bound:** Both SOL < 40% but `nsys` shows GPU idle time → bottleneck is host-side or sync.

## MFU calculation (training)

**MFU = observed_FLOPs / peak_FLOPs**, computed across an iteration.

**Origin:** PaLM 540B paper ([arxiv 2204.02311, Chowdhery et al. 2022](https://arxiv.org/abs/2204.02311)). PaLM achieved MFU = 46.2% (HFU 57.8% counting recompute).

**Two related metrics:**
- **MFU** counts only "useful" FLOPs (forward + backward + parameter update of unique tokens). Approximation: `6 × N × D` where N = parameters, D = tokens.
- **HFU** (Hardware FLOPs Utilization) counts all FLOPs the hardware actually executed, including activation recompute and gradient checkpointing.

HFU > MFU when checkpointing is used. The gap quantifies recompute overhead.

### Llama 3 (16K H100, 2024)

> "we achieve an overall BF16 Model FLOPs Utilization (MFU; chowdhery2023palm) of 38-43% for the configurations shown in Table 4. The slight drop in MFU to 41% on 16K GPUs with DP=128 compared to 43% on 8K GPUs with DP=64 is due to the lower batch size per DP group."
> — [arxiv 2407.21783 §3.3.2](https://arxiv.org/abs/2407.21783)

Hardware: 16,384 H100 80GB SXM (HBM3, 3.35 TB/s, 989 TFLOPS dense BF16). Parallelism: 4D (TP × PP × DP × CP).

### DeepSeek-V3 (2,048 H800, 2024)

The DeepSeek-V3 paper ([arxiv 2412.19437](https://arxiv.org/abs/2412.19437)) reports H800-hours but **not MFU directly**. The often-quoted "21.4% FP8 MFU" / "42.9% BF16-equivalent MFU" is a community calculation:

> "After running calculations, 21.4% MFU for fp8 was achieved, which is equivalent to 42.9% MFU for bf16. The H800 GPU has a specification of 989 TFLOPS for BF16, and 1979 TFLOPS for FP8."
> — [Medium article on DeepSeek-V3 MFU](https://medium.com/@dlrover/what-is-the-mfu-for-deepseek-v3-training-0d9ea4d42eb4)

**Note:** H800 is the export-restricted variant of H100 with bandwidth-throttled NVLink. Compute is identical to H100 SXM5 (989 TFLOPS BF16); NVLink bandwidth is throttled (~400 GB/s vs 900 GB/s).

### MFU benchmarks (the production bar)

| Model / framework | MFU (BF16 unless noted) | Hardware | Source |
|---|---|---|---|
| PaLM 540B | 46.2% (HFU 57.8%) | 6,144 TPU v4 | PaLM paper 2022 |
| **Llama 3 405B** | **38–43%** | 8,192–16,384 H100 SXM5 | Llama 3 paper 2024 |
| **DeepSeek-V3 671B (MoE 37B active)** | **~42.9% BF16-equivalent (21.4% FP8)** | 2,048 H800 | community-derived, 2024 |
| GPT-NeoX-20B | ~38% | 96 A100 | EleutherAI public stats |
| BLOOM-176B | ~30% | 384 A100 | HuggingFace public retro |
| Megatron-LM 530B (Megatron-Turing NLG) | ~38% | 2,240 A100 | Megatron-LM paper 2022 |

**The bar:** for production transformer training in 2026:
- **>50% BF16 MFU** = excellent, hard to beat without algorithmic gains.
- **38–45% BF16 MFU** = production-acceptable; matches frontier labs.
- **30–37% BF16 MFU** = mediocre; investigate bottleneck (likely overhead or comm-not-overlapped).
- **<30% BF16 MFU** = broken; something in the dataloader, NCCL, or graph-break logic is wrong.

## Inference throughput (different metric, different bars)

Training MFU translates poorly to inference because:
- Decode is memory-bandwidth-bound, not compute-bound (gpu-ml-judgment §3 / §16).
- Prefill is compute-bound (matmul-dominated), separate optimization regime.
- Common metric: **tokens/sec/GPU at SLO** (TTFT for prefill, TPOT for decode).

Targets per [vLLM benchmarks](https://github.com/vllm-project/vllm) and [TensorRT-LLM perf studies](https://github.com/NVIDIA/TensorRT-LLM):

| Model / setup | Target | Hardware |
|---|---|---|
| Llama-3 70B FP16 decode, batch=1, seq=2K | ~30 tok/s | 1× H100 SXM5 |
| Llama-3 70B FP8 decode, batch=64, seq=2K | ~3,000 tok/s aggregate | 1× H100 SXM5 |
| Llama-3 70B BF16 prefill (TTFT) | <500 ms for 4K context | 1× H100 SXM5 |
| Mixtral-8×7B FP16 decode | ~80 tok/s @ batch=1 | 1× H100 SXM5 |

These are wall-clock production numbers; verify against your own workload before quoting.

## Wave quantization (Horace He's worked example)

**Source:** Horace He, "What Shapes Do Matrix Multiplications Like?" ([thonking.ai, Apr 2024](https://www.thonking.ai/p/what-shapes-do-matrix-multiplications)).

The exact A100 example:

> "Using the profiler, we see that we're running a CUTLASS-based matmul with a tile size of 256x128. Note that our matmul kernel doesn't change at all, but our perf drops from 60+ TF/s at N=1791 to 43 TF/s at N=1793."

**The math:**
- A100 has **108 SMs**.
- N=1792, tile 256×128: grid = (1792/256) × (1792/128) = 7 × 14 = **98 tiles**. 98 < 108 → **1 wave**, ~91% SM utilization. ~60 TFLOPS.
- N=1793, tile 256×128: grid = 8 × 15 = **120 tiles**. 120 > 108 → **2 waves**: first wave 108 tiles (full), second wave 12 tiles (~11% SM utilization). Average ~55% utilization. ~43 TFLOPS — **30% drop from one element**.

**Detection in `ncu`:**

```bash
ncu --section LaunchStats --section SpeedOfLight -k regex:matmul -o waves ./app
```

Read in `ncu-ui` Launch Statistics:
- `# Waves Per SM` — fractional values like 1.11 indicate one full wave plus partial second wave.
- Cross-reference with SOL: low SM utilization with high LaunchStats wave-fraction → wave quantization.

There is **no single dedicated "wave quantization" metric** in ncu. Detection is multi-cell: LaunchStats + SOL + Occupancy together.

**Practical heuristic:** for matmul shapes, choose dimensions that fit cleanly into `(tile × num_SMs / k)` for integer k. A100 with tile 256×128: align inner dims to multiples of `108 × 256 = 27648` along M axis or `108 × 128 = 13824` along N. H100 (132 SMs): multiples of `132 × 256 = 33792` or `132 × 128 = 16896`. This is why production transformer vocabularies use 50,304 not 50,257 — the LM head matmul falls off a wave boundary at 50,257.

## Worked examples

### Compute-bound: FlashAttention-3 on H100 SXM5

**Setup:** FA3 kernel, 70B-class model, BF16, H100 SXM5.

**Profile:**

```bash
ncu --replay-mode range \
    --nvtx-include 'attention_forward' \
    --section SpeedOfLight \
    --section ComputeWorkloadAnalysis \
    --section MemoryWorkloadAnalysis \
    --metrics regex:sm__inst_executed_pipe_tensor_op_.*\.avg\.pct_of_peak_sustained_active \
    -o fa3_profile ./app
```

**Read:**
- SOL Compute %: ~75% (target).
- Tensor pipe utilization: 70–80%.
- DRAM throughput: 30–40% (well below saturation; HBM is not the bottleneck).
- Verdict: compute-bound, achieved performance ~740 TFLOPS / 989 TFLOPS dense = **75% utilization** ([FA3 paper](https://arxiv.org/abs/2407.08608)).

**Cross-check:** `cuobjdump --dump-sass <bin> | grep GMMA` — should see wgmma instructions. If only `HMMA.16816.F32.BF16` appears (not `HMMA.F8.*`), FP8 path silently fell back to BF16 ([flash-attention #1848](https://github.com/Dao-AILab/flash-attention/issues/1848)).

### Memory-bound: 70B LLM decode

**Setup:** Llama-3 70B, BF16, batch=4, seq=2K, decode (single token at a time).

**Profile:**

```bash
ncu --section SpeedOfLight \
    --section MemoryWorkloadAnalysis \
    --metrics dram__throughput.avg.pct_of_peak_sustained_elapsed,\
sm__warps_active.avg.pct_of_peak_sustained_active \
    -k regex:gemv\|attention_decode \
    -o decode_profile ./app
```

**Read (typical):**
- SOL Memory %: 75–85% (saturated).
- DRAM throughput: ~2.5 TB/s on H100 SXM5 (75% of 3.35 peak).
- SOL Compute %: 5–10% (tensor cores idle).
- Tensor pipe utilization: <5%.
- Verdict: memory-bound. Tokens/sec is HBM-limited.

**Calculate AI:** 70B BF16 model = 140 GB. Per token: read all weights (140 GB) + read KV cache. AI ≈ 2 FLOPs/byte (gemv at batch=1) — way below H100 ridge of 295. Memory-bound by Roofline math.

**Fixes (from gpu-ml-judgment §16, §47):**
- Bigger batch → AI grows (gemv → gemm). batch=64 yields AI ~30 still memory-bound; batch=512 maybe approaches ridge.
- KV cache quant (8-bit, 4-bit) → halves bytes per token.
- Speculative decoding → fewer decode steps per accepted token.
- Move to H200 (4.8 TB/s vs 3.35) → ~45% faster decode, no code change.

### Overhead-bound: PyTorch training with stale data loader

**Setup:** small ResNet-50 training, batch=32, 1× A100, custom DataLoader with synchronous PIL augmentation in worker.

**Profile:**

```bash
nsys profile -t cuda,nvtx,osrt,python-gil -o overhead_profile python train.py

nsys stats overhead_profile.nsys-rep | head -30
```

**Read:**
- GPU idle %: 60% (ouch).
- Long red bars in Python GIL trace.
- Kernel times sum to 40% of iteration time.
- Verdict: overhead-bound. The kernel is fine; CPU-side data loading is the bottleneck.

**Fixes:**
- `num_workers > 0`, `pin_memory=True`, `prefetch_factor=4`.
- Move augmentation to GPU (DALI, Kornia).
- Verify with another `nsys` profile after the fix.

`ncu` would have given counter values for the kernel — useful but not the answer. The answer is in `nsys`'s timeline view.

## Why there is no clean GPU TMA

Yasin's [Top-Down Method (ISPASS 2014)](https://rcs.uwaterloo.ca/~ali/cs854-f23/papers/topdown.pdf) categorizes CPU work into Frontend / Backend / Bad-Speculation / Retiring buckets. The structure relies on:
- A clear frontend (fetch/decode) vs backend (execute/retire) divide.
- Branch prediction with rollback for bad speculation.
- A dispatch slot accounting model.

GPUs don't fit:
- No branch prediction with rollback — predicate masking executes both paths, no "bad spec."
- Frontend (warp scheduler) and backend (execution) are interleaved; warps on a barrel scheduler swap freely.
- Dispatch slots accounting requires a wgmma/SIMT-aware model that doesn't exist as a standardized framework.

**Closest analogs:**
1. **Speed of Light + Roofline.** What NVIDIA actually ships. Per-unit %SOL with a decision tree.
2. **DrGPU** ([ICPE 2023](https://research.spec.org/icpe_proceedings/2023/proceedings/p43.pdf)) — academic. Decomposes stall cycles by reason, pinpoints root causes. Targets Volta/Turing/Ampere. Not maintained as a stable production tool.
3. **GPUscout** (TUM) — uses CUPTI PC sampling for memory-bottleneck localization.

For practitioners: Roofline + SOL + WarpStateStats + DrGPU's framework-style stall decomposition (which `ncu`'s SourceCounters approximates) is the closest stack to "GPU TMA."

## Common gotchas

1. **Sparse vs dense numbers.** NVIDIA marketing headlines sparse (2:4) — dense is half. Use dense for roofline unless you have explicit 2:4 sparsity in the model.
2. **H100 PCIe vs SXM5.** Different compute (756 vs 989 BF16) and different bandwidth (2.0 vs 3.35 TB/s). PCIe is HBM2e, not HBM3.
3. **H800 is bandwidth-throttled H100.** Same compute, NVLink throttled. DeepSeek-V3 trained on these.
4. **B200 has two variants.** 1000W HGX = 2,250 BF16; 1200W GB200 = 2,500 BF16. The "20 PFLOPS sparse FP4" claim is GB200 1200W.
5. **MFU formula sensitive to "what counts as FLOP."** Use the 6ND approximation consistently; HFU includes recompute.
6. **DeepSeek-V3 21.4% MFU is community-derived**, not in the paper.
7. **Wave quantization affects only the inner dim of matmul.** M outer can be any size; N or K inner must align.
8. **`ncu`'s wall-clock is unreliable for overlap-sensitive kernels.** Use `cudaEvent` timing for the wall-clock claim; ncu for counter values.
9. **Roofline diagonals are theoretical.** Real kernels rarely achieve 100% of either peak. Achievable realistic targets: 85–95% of peak DRAM bandwidth, 70–90% of peak compute.
10. **L2 cache size determines whether "small" working sets fit.** Different per-arch (40 MB A100, 50 MB H100, 60 MB B200, 96 MB L40S, 128 MB RTX 5090). Major impact on hierarchical roofline.

## References

- [Williams, Waterman, Patterson — Roofline (CACM 2009)](https://dl.acm.org/doi/10.1145/1498765.1498785)
- [Yasin — Top-Down Method (ISPASS 2014)](https://rcs.uwaterloo.ca/~ali/cs854-f23/papers/topdown.pdf)
- [PaLM paper (MFU origin) — arxiv 2204.02311](https://arxiv.org/abs/2204.02311)
- [Llama 3 paper — arxiv 2407.21783](https://arxiv.org/abs/2407.21783)
- [DeepSeek-V3 paper — arxiv 2412.19437](https://arxiv.org/abs/2412.19437)
- [DeepSeek-V3 MFU community derivation](https://medium.com/@dlrover/what-is-the-mfu-for-deepseek-v3-training-0d9ea4d42eb4)
- [FlashAttention-3 paper — arxiv 2407.08608](https://arxiv.org/abs/2407.08608)
- [FlashAttention-3 blog (Tri Dao)](https://tridao.me/blog/2024/flash3/)
- [Horace He — Wave Quantization (thonking.ai)](https://www.thonking.ai/p/what-shapes-do-matrix-multiplications)
- [Horace He — Brrrr First Principles (horace.io)](https://horace.io/brrr_intro.html)
- [NVIDIA blog — Roofline with Nsight Compute](https://developer.nvidia.com/blog/accelerating-hpc-applications-with-nsight-compute-roofline-analysis/)
- [NVIDIA blog — Peak-Performance-Percentage Method](https://developer.nvidia.com/blog/the-peak-performance-analysis-method-for-optimizing-any-gpu-workload/)
- [DrGPU — ICPE 2023](https://research.spec.org/icpe_proceedings/2023/proceedings/p43.pdf)
- [Glenn Lockwood — MFU notes](https://www.glennklockwood.com/garden/MFU)
- [Microbenchmarking Hopper — arxiv 2402.13499](https://arxiv.org/abs/2402.13499)
- [Microbenchmarking Blackwell — arxiv 2512.02189](https://arxiv.org/html/2512.02189v1)
- [vLLM PagedAttention — arxiv 2309.06180](https://arxiv.org/abs/2309.06180)
- [Megatron-LM paper (multi-thousand-GPU MFU)](https://people.eecs.berkeley.edu/~matei/papers/2021/sc_megatron_lm.pdf)
