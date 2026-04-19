# Senior GPU/ML Performance Engineering Judgment

A decision framework for GPU kernel work and ML training/inference perf, not a checklist. Each topic is how a staff engineer thinks about the trade-off, written for a mid-level who knows what a CUDA core is but hasn't internalized when to ignore the textbook.

This file sits on top of `perf-judgment.md` (universal hardware-and-methodology). It adds the GPU/ML-specific judgment perf-judgment correctly excluded as out of scope: SIMT execution, the Nsight toolchain, HBM/L2/shared/register hierarchy, FlashAttention as the canonical kernel-fusion case, mixed precision, quantization, 3D parallelism, KV-cache-centric inference serving, and the hardware economics of the 2024–2026 landscape. Cite perf-judgment inline when invoking a principle from it (e.g., Roofline, Coz, Amdahl's law) rather than restating.

Currency: all claims below are stamped as-of 2026-04. This space moved meaningfully between 2022 (pre-FlashAttention, FP16 default, paged attention didn't exist) and 2026 (FA3 on Hopper, FP8 training validated at 671B, paged attention as table-stakes, disaggregated prefill/decode in production). Date-stamped claims are flagged; treat any "current SOTA" as a 6-month-expiring assertion.

---

## Profile-Guided Or Not At All — GPU Edition

You haven't optimized a kernel until the Nsight Compute metric you targeted moved. You haven't sped up training until MFU went up. You haven't sped up inference until tokens/sec/GPU at the SLO moved. The discipline is non-negotiable:

1. **Measure with the right tool in the right order.** `nsys` for the timeline (where does training time actually go — CPU dispatch, data loader, NCCL, kernel execution?). `ncu` for kernel-level counters (SM occupancy, achieved DRAM bandwidth, tensor-core utilization, stall reasons). PyTorch profiler with Chrome-trace integration for framework-level dispatch. **nsys before ncu** — if your data loader is the bottleneck, ncu on a kernel is wasted effort.
2. **Diagnose the regime.** Horace He's taxonomy from "Making Deep Learning Go Brrrr From First Principles" (horace.io/brrr_intro.html, Mar 2022) is the right mental model: compute-bound, memory-bound, or overhead-bound. The fix family differs. SIMD/tensor-core work doesn't help a memory-bound kernel. Fusing kernels doesn't help an overhead-bound dispatch loop.
3. **Read the SASS.** PTX is the portable ISA; SASS is what actually runs. `cuobjdump --dump-sass` shows you HMMA/QGMMA/UMMA firing (or not). Tensor-core usage cannot be verified by `nvidia-smi` busy % — the only reliable check is `sm__inst_executed_pipe_tensor_op_hmma.avg.pct_of_peak_sustained_active` from ncu or SASS inspection. Many "FP16 matmul" kernels silently fall back to CUDA cores.
4. **Fix with the smallest change that should move the counter.**
5. **Re-measure with the same counter.** If SM occupancy was 15% and your fix targeted occupancy, check occupancy, not wall-clock. Wall-clock alone is Mytkowicz-level noise (perf-judgment §2).

If you skipped any step, you guessed. Tri Dao put it sharply (@tri_dao on X, Feb 2025): "One way to tell that the AI-written kernel is wrong without even reading the code is that it's way too fast — 1800 TFLOPS of FP32 on H100, 30× the theoretical max." If your number exceeds the roofline, your verifier is broken, not your speedup real.

**The smell:** A "perf improvement" PR with no nsys timeline, no ncu metric before/after, no MFU number, no tokens/sec-at-SLO measurement. The author is guessing and dressed up the guess as engineering.

**The signal:** Every claim has a counter or a workload metric behind it. "Achieved DRAM bandwidth went from 40% to 85%, end-to-end iteration time dropped 20%, MFU moved from 38% to 47%." That's optimization. Anything else is hope.

---

## §1. SIMT Execution And The Occupancy Fallacy

### 1. Occupancy Is A Means, Not The Metric

Vasily Volkov's "Better Performance at Lower Occupancy" (GTC 2010, nvidia.com/content/GTC-2010/pdfs/2238_GTC2010.pdf) is the canonical demolition of the "maximize occupancy" rule. His matrix-multiply kernel with 8× smaller thread blocks and 2× lower occupancy achieved 1.6× higher performance; his FFT, 4× smaller blocks, 2× lower occupancy, 2× performance. The mechanism is ILP over TLP: more work per thread, more registers per thread to dodge shared memory, let the compiler pipeline better.

That was Tesla-era (GT200). It still holds on Ampere/Hopper. NVIDIA's own cuTLASS docs are explicit: "accumulator elements typically occupy at least half of a thread's total register budget, which consequently results in relatively low occupancy compared to other GPU workloads." FlashAttention-2 runs at ~35% SM utilization on H100 per Tri Dao's FA3 blog (tridao.me/blog/2024/flash3/, Jul 2024) — and that's the baseline FA3 is 1.5–2× over.

**The smell:** A perf review comment that says "occupancy is only 25%, bring it up" on a kernel that's register-blocked for Tensor Core accumulators. The reviewer is reading from a 2015 best-practices guide.

**The signal:** You target SM occupancy when your kernel is latency-bound on global memory loads with shallow ILP; you leave it low when your kernel is register-blocked and the accumulator fragments need register residency.

### 2. Warp Divergence Serializes Through Both Paths

32 threads per warp execute in lockstep. If-branches where threads diverge force the warp to execute both paths with predicate masking — sum of both path costs, not max. Predicate masking helps, but doesn't eliminate it.

The senior heuristic: hoist the divergent decision to block granularity, not thread granularity. Launch two kernels, or two block groups, rather than branching inside a warp. For data-dependent divergence you can't hoist (e.g., early-exit on per-thread convergence), measure the divergence rate with ncu's `smsp__thread_inst_executed_per_inst_executed` — below 0.8 means you're burning cycles on masked lanes.

**The smell:** An inner-kernel `if (thread_condition) { heavy_work() }` with no thought given to warp-level coherence of `thread_condition`.

### 3. Coalesced Access Is The First Thing To Check

128B-aligned reads from a warp coalesce into one memory transaction; misaligned or strided patterns issue multiple transactions and waste bandwidth. This is the single most common cause of "why is my custom kernel 5× slower than cuBLAS." Layout transformations — AoS → SoA, stride-coalescing, or explicit shared-memory staging — are the fix.

Check with ncu's `l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum.per_request` — if it's above 4 on a contiguous load, you're misaligned. NVIDIA Ampere+ GPUs have some tolerance via the read-only / texture cache paths; don't rely on it.

**The smell:** Custom kernel for a transformer layer with strided weight reads because "that's how the tensor is laid out in PyTorch." Transposing once at load time usually wins.

### 4. Shared Memory Bank Conflicts — Stride Is The Real Fix

NVIDIA shared memory has 32 banks. Two threads in a warp hitting the same bank (with different addresses) serialize. The textbook fix is padding the leading dimension: `shared[TILE][TILE+1]`. It works and is cheap memory-wise.

The senior fix is choosing an access stride that distributes naturally — swizzling the layout so the conflict doesn't arise. Modern CUTLASS uses swizzle patterns for exactly this. Padding is a hint that you haven't picked the right layout; on dense GEMM tiles, swizzle wins for free because there's no wasted shared memory.

**The smell:** Adding `+1` padding everywhere without checking whether the conflict actually fires in ncu's `smsp__l1tex_data_bank_conflicts_pipe_lsu.sum`.

### 5. Register Spills Are A Compute Cliff, Not A Slowdown

Too many simultaneously-live values → compiler spills to "local memory," which is actually DRAM, not cache. `--ptxas-options=-v` shows the register count per thread. When you see "XX bytes stack frame" in the ptxas output, you have spills. Each spill is a several-cycle round-trip to DRAM: catastrophic for a hot loop.

`nvcc -maxrregcount=N` caps registers and is almost always the wrong answer — it re-creates the spill problem at the cap. The right fix is structural: reduce unrolling factor, shrink tile size, split the kernel. If your kernel has a 200-register inner loop and is running at 40% DRAM bandwidth, register pressure is why.

**The smell:** A template-heavy CUTLASS-style kernel with `-maxrregcount=64` in the build flags. Someone traded compute for compute and called it a win.

### 6. Warp Specialization Is The Hopper Pattern

Pre-Hopper, warps were symmetric: same register count, same work. Hopper introduced `setmaxnreg` to dynamically reallocate registers across warp groups at runtime. FlashAttention-3 and CUTLASS Ping-Pong use this aggressively: producer warps `setmaxnreg` down to 40 registers (they only issue TMA loads), consumer warps up to 232 (they do the actual wgmma matmul). Asymmetric allocation lets the SM hold more of the right kind of warp.

If you're writing Hopper kernels and your producer/consumer warps have the same register count, you're leaving ~20% of throughput on the table. The pattern isn't optional at FA3-class perf.

**The smell:** A "Hopper-optimized" kernel that ports the Ampere producer-consumer split 1:1 without asymmetric register allocation.

---

## §2. GPU Profiling Tools And Diagnostic Discipline

### 7. nsys For The Timeline, ncu For The Counters — In That Order

Nsight Systems (`nsys`) gives you the system-wide timeline: CPU dispatch, CUDA stream activity, NCCL collectives, kernel execution, gaps. Nsight Compute (`ncu`) gives you per-kernel metrics via replay-based collection. The discipline: nsys first to identify the hot kernel or the gap that dominates iteration time, then ncu to understand why that kernel is slow.

Engineers who start with ncu on kernel X waste cycles when X was only 10% of iteration time and the data loader was 60%. nsys will show 40% GPU idle and you'll never run ncu. The symptom of skipping nsys: "we optimized kernel X by 3× and end-to-end training only got 8% faster."

**The smell:** An ncu report attached to a PR with no nsys timeline. You don't know if the kernel you're optimizing is in the critical path.

### 8. ncu Replay Distorts Attention Kernels 3–4×

Dao-AILab/flash-attention#1202: "Nsys/Ncu shows 3x-4x slower execution times than expected based on theoretical FLOP calculations." ncu replays kernels to collect counters and serializes launches in the process — the overlap FlashAttention carefully orchestrates (async TMA + wgmma) is destroyed. The same pattern hits any kernel that relies on cross-stream or cross-warpgroup overlap: FA3, CUTLASS Ping-Pong, NCCL collectives.

Never use ncu-reported wall-clock for micro-benchmark comparison. Use it for counter analysis only, and measure wall-clock in nsys (or in `cudaEvent` timing outside the profiler).

**The smell:** A Twitter thread comparing kernel A vs kernel B via ncu-reported "duration." The comparison is meaningless for any fused or overlapping kernel.

### 9. ncu On NCCL Kernels Is Actively Misleading

NVIDIA/nccl#466 documents the same phenomenon for collectives: ncu serializes the NCCL kernel and destroys the comm/compute overlap you're trying to measure. Measuring overlap with ncu is measuring the absence of the thing you care about.

For NCCL diagnosis, use nsys to see whether the NCCL kernel actually overlaps the backward matmuls on the timeline. If NCCL kernels sit on their own stream with no compute above them, overlap isn't happening. The fix is usually scheduling (separate high-priority stream for NCCL, SM count allocation) or using SM-free collectives like NVSHMEM.

### 10. The Five Metrics That Cover 80% Of Diagnoses

Learn these; most "why is this slow" questions route through them:

- **SM occupancy** (`sm__warps_active.avg.pct_of_peak_sustained_active`) — are you filling the SM?
- **Achieved DRAM bandwidth** (`dram__throughput.avg.pct_of_peak_sustained_elapsed`) — are you memory-bound and extracting it?
- **Tensor core utilization** (`sm__inst_executed_pipe_tensor_op_hmma.avg.pct_of_peak_sustained_active`) — are tensor cores actually firing?
- **Warp execution efficiency** (`smsp__thread_inst_executed_per_inst_executed.ratio`) — how much divergence?
- **Stall reasons** (`smsp__warp_issue_stalled_*`) — waiting on long-latency loads, barriers, or something else?

ncu's default "SpeedOfLight" section gives you most of these at a glance. If a counter isn't in your analysis, you're not looking at the bottleneck.

**The signal:** You describe the diagnosis in terms of which of the five moved, not in terms of "it's faster now."

### 11. GPU Idle % Is The First Thing To Check, Not The Kernel Cost

"When the GPU idles at 40–70%, the bottleneck is almost always I/O, decoding, or collation" (the canonical dataloader-bottleneck diagnosis). The top-5-kernels view hides 60% GPU idle time. Check `nvidia-smi` utilization *during* training — if it's below 90% consistently, optimizing a kernel won't help until you fix the dispatch side.

The hot kernel is often not the bottleneck in the Amdahl sense. This is the single most common antipattern for new ML engineers: spending a week optimizing the attention kernel when the dataloader is GIL-bound at 40% GPU utilization.

### 12. nvprof Is Deprecated — Stale Tutorials Are A Red Flag

If you see `nvprof` in a 2024+ tutorial, someone copy-pasted 2018 docs. `nvprof` stopped working properly on Volta+ years ago. nsys/ncu replaced it. Same for `nvvp` (Visual Profiler). Any resource citing these as current is teaching from an obsolete toolchain and probably has stale API advice elsewhere too.

### 13. PyTorch Profiler Is The Framework-Level Tool, Not An Nsight Replacement

`torch.profiler` + Chrome trace gives you the framework-level timeline: operator dispatch, Python overhead, CUDA kernel launches per op, memory allocations. Use it to answer "why is my PyTorch training slow" *before* going to nsys for kernel-level questions. The dispatch overhead pattern (too many tiny kernel launches, CPU-bound dispatch loop) is visible in PyTorch profiler; nsys shows it as gaps but doesn't attribute to Python.

`torch.cuda.Event` timing is for sub-kernel measurements when you know what you're timing. `torch.utils.bottleneck` is broken on multi-worker dataloaders (pytorch/pytorch#6313) — it crashes with `num_workers > 0`, the exact configuration you want to profile.

**The signal:** You use PyTorch profiler first for framework-level questions, nsys for system-level, ncu for kernel-level — and know which category your question falls into.

---

## §3. GPU Memory Hierarchy — Know The Numbers

### 14. HBM Bandwidth Is The Ranking Metric, Not FLOPs

Tim Dettmers' "Which GPU(s) to Get for Deep Learning" (timdettmers.com, 2023): "One of the single best indicators for each GPU's performance is their memory bandwidth." At GPT-3 scale, Tensor Cores are idle 35–55% of the time because memory can't feed them. The 2023 hierarchy Dettmers argues: Tensor Cores → memory bandwidth → cache → FLOPs.

The generational numbers (2026-04, verify via vendor product page before quoting):

- **A100 80GB SXM4:** HBM2e ~2 TB/s, 108 SMs, 40 MB L2, 164 KB user shared mem/SM.
- **H100 SXM5:** HBM3 at **3 TB/s (launch spec) / 3.35 TB/s (current shipping SKU)** — the Hopper architecture blog says 3 TB/s, the product page says 3.35 TB/s. 132 enabled SMs, 50 MB L2, 228 KB user-configurable shared mem/SM (out of 256 KB combined L1+shared), 700 W.
- **H100 PCIe:** 114 SMs, HBM2e at ~2 TB/s (not HBM3) — the "H100 = HBM3" 2023 assumption is wrong for PCIe.
- **H200 SXM5:** **same GH100 die as H100.** Only memory changes — 141 GB HBM3e at 4.8 TB/s. Real-world gain: ~45% faster LLM inference when memory-bound; negligible when compute-bound.
- **B200 (Blackwell, shipping 2024–2025):** 192 GB HBM3e, up to 20 PFLOPS sparse FP4 peak. NVLink 5 = 1.8 TB/s (2× NVLink 4). GB200 NVL72 rack: 130 TB/s aggregate NVLink.

Memory-bound workloads scale near-linearly with bandwidth. H100 → H200 is ~60% more HBM BW, about 45% faster LLM decode in practice. Most LLM decode is memory-bound, so the H200 memory boost matters for serving more than for training.

### 15. The AI Memory Wall Is Quantitative

Gholami, Yao, Kim, Keutzer, Mahoney's "AI and Memory Wall" (arXiv 2403.14123, IEEE Micro 2024) gives the ratios: **FLOPs have grown 3.0× every 2 years over the last 20; DRAM bandwidth 1.6×/2yr; interconnect 1.4×/2yr.** Compute is outrunning memory, which is outrunning interconnect. Decoder models hit the wall first because KV-cache autoregression is pure memory-read per token.

Cite this when someone says "we need more FLOPs." The answer for inference is almost always "no, you need more bandwidth, smaller KV cache, or more batching." Roofline analysis (perf-judgment §55) shows most LLM kernels are memory-bound on modern hardware.

### 16. The H100 Arithmetic-Intensity Threshold Is 591 FLOPs/byte

For H100 BF16: peak compute ≈ 989 TFLOPs/s; HBM BW ≈ 3.35 TB/s → threshold ≈ 295 FLOPs/byte. For H100 FP8, the threshold doubles (~591 FLOPs/byte). **LLM decode sits well below either:** a 70B FP16 model decode transfers ~140 GB per token step — you're miles below the roofline. The fix isn't faster MMA; it's KV compression, speculative decoding, bigger batches.

Senior diagnostic: compute the arithmetic intensity of your kernel (FLOPs / bytes transferred) before picking an optimization. If you're below threshold, compute-side optimizations (FP8, tensor-core use) won't help until you're memory-saturated first.

**The smell:** "We're switching to FP8 for 2× speedup on decode." FP8 doubles the threshold you're already 10× below. The decode speedup from FP8 weights is bandwidth (half the bytes/weight), not compute.

### 17. L2 Cache Matters For Working Sets That Fit

A100 has 40 MB L2; H100 has 50 MB; H200 60 MB. A 7B model's KV cache for a 4K-context batch doesn't fit. A 0.5B embedding matrix does. The judgment: for kernels where the working set fits in L2, L2 hit rate is the metric (`lts__t_sector_hit_rate.pct`). For kernels where it doesn't, L2 is effectively a prefetch buffer and DRAM bandwidth is what matters.

Modern H100/H200 serving stacks explicitly partition models to stay L2-resident where possible. The 60 MB L2 on H200 is large enough to cache a 40 GB model's hot subset across layers if you're careful with layout.

### 18. Register File Pressure Is The Unseen Cliff

256 KB register file per SM on Ampere (per-thread cap 255 registers). Exceed it → spills to "local memory," which is actually DRAM. The resulting slowdown doesn't look like a register issue in a shallow profile; it looks like low arithmetic intensity and high DRAM traffic. Check `--ptxas-options=-v` for the register count and whether there's a "stack frame" warning. If you see `NN bytes stack frame`, you have spills.

**The smell:** A kernel reporting 70% DRAM bandwidth when you expected it to be compute-bound. Suspect spills before you suspect anything else.

### 19. TMA And Async Copy On Hopper Are Not Optional For Peak Perf

Tensor Memory Accelerator (Hopper-only): dedicated copy engine, 1D–5D transfers between GMEM↔SMEM and SMEM↔SMEM within a cluster. Single-thread issues; frees warps for compute. This is what enables FA3's warp specialization: producer warps issue TMA loads while consumer warps do wgmma.

**TMA alignment violations are undefined behavior, not graceful fallback.** From NVIDIA's CUDA programming guide: "`cuda::device::memcpy_async_tx` and `cuda::ptx::cp_async_bulk` always use TMA and will result in undefined behavior if the requirements are not met." Pointers must be 16B-aligned global, 128B-aligned shared; sizes must be multiples of 16B. Violate and you get silent corruption, not a slowdown.

The higher-level `cuda::memcpy_async` silently falls back to synchronous when alignment slips. Your "async" path may be serial if you didn't check SASS for LDGSTS (Ampere) or the Hopper bulk-async variants. Check the assembly; don't trust the API name.

**The smell:** Writing a Hopper kernel with `cuda::memcpy_async` and misaligned offsets, expecting async overlap. You got sync copies and paid for the setup cost anyway.

### 20. Unified Memory Kills Production Performance

Managed memory / unified memory (`cudaMallocManaged`) is fine for prototyping small kernels. In production training, every page fault is multi-microsecond, and the driver migrates pages at access time. The resulting latency spikes are invisible in kernel timing but dominate wall-clock.

Never ship a training loop with managed memory. Use explicit `cudaMemcpy` or PyTorch's allocator, which keeps allocations on-device.

### 21. Horace He's Wave Quantization — One-Element Shape Change, 30% Drop

From thonking.ai "What Shapes Do Matrix Multiplications Like?" (Apr 2024): on A100 (108 SMs) with CUTLASS 256×128 tile, **N=1792 yields 7×14 = 98 tiles (1 wave) at 60+ TFLOPs/s; N=1793 yields 8×15 = 120 tiles (2 waves) at 43 TFLOPs/s.** One element larger on the inner dim, ~30% perf drop. The second wave is mostly idle SMs, but you pay its full launch cost.

Only the *inner* dimension's evenness matters. M=2047, K=N=2048 is fine; K or N = 2047 is not. This is why vocab=50257 transformer models are measurably slower than vocab=50304 — the LM head matmul falls off a wave boundary. Horace's practical heuristic: "10–15% additional performance available in each matmul by choosing shapes more carefully."

**The smell:** Model dimensions like 50257, 1537, 2049 chosen by the researcher for "reasons." The perf engineer rounds them to a multiple of (tile × num_SMs / factor) and gets 10% back for free.

**The signal:** Your model dimensions are chosen with wave quantization in mind, and you can explain why the LM head uses vocab=50304 instead of 50257.

---

## §4. Kernel Design — Triton, CUDA C++, CUTLASS/CuTe, cuBLAS

### 22. cuBLAS Is The Upper-Bound Measuring Unit, Not Your Competition

Karpathy's framing from the llm.c discussions (github.com/karpathy/llm.c/discussions, May 2024): "cuBLAS is the upper-bound measuring unit." You don't beat cuBLAS on standard shapes — the library has been tuned for years across every SM generation. You measure how close a readable manual kernel gets. llm.c's manual CUDA kernels hit ~80% of cuBLAS for FP32 GPT-2 matmul in ~2000 lines, which is the point: educational transparency, not production deployment.

The production rule: start with cuBLAS/cuDNN. Only write a custom kernel when you have a specific shape that falls off their heuristic (small batch, odd dtype, fused epilogue) or when you need to fuse operations the library doesn't fuse (e.g., flash-style attention).

### 23. Triton Is The 2026 Default Research-Grade Kernel Language

Phil Tillet's Triton (MAPL 2019, openai.com/research/triton) shifted kernel writing from thread-level (CUDA C++) to tile-level. You express "this block of threads processes this tile of data"; the compiler handles thread mapping, coalescing, shared-memory scheduling, bank-conflict avoidance. Matches hand-tuned cuBLAS/cuDNN for GEMM and conv on many shapes; the FlashAttention reference kernel is written in Triton.

Triton's trade: ~10–25% off hand-tuned CUTLASS for the most aggressive matmul perf on Hopper. Modular's critique (Democratizing AI Compute Part 7, modular.com, 2025) names the ceiling: "trades performance for productivity." Acceptable trade for research; unacceptable if you're serving at scale and the 20% is millions of dollars.

Triton on ROCm is functional as of ROCm 7 (Triton 3.3.0) — a 2026 fact that was not true in 2023. Triton on Apple Silicon still doesn't exist; PyTorch uses Metal kernels instead.

**The smell:** Writing hand-CUDA for a matmul-variant kernel in 2026. Unless you've measured Triton and it's leaving > 20% on the table, you're spending engineering on something the compiler can do.

### 24. CUTLASS / CuTe Is The Power-User Path For Peak Hopper/Blackwell

FA3 is built on CUTLASS; TensorRT-LLM uses CUTLASS for peak Hopper perf. Scott Gray's Maxwell SGEMM (github.com/NervanaSystems/maxas, ~2015) was the last time a single engineer hand-writing SASS beat cuBLAS — 98.5% theoretical peak on GM107, beating cuBLAS by 25% on small N. The mechanism wasn't algorithmic; it was register-bank-conflict scheduling and dual-issue FFMA. Modern CUTLASS replaces that labor with template metaprogramming.

CUTLASS 3.x introduced CuTe (layout algebra for tile mappings); CUTLASS 4.x (2025) exposes CuTe as a Python DSL. If you need Hopper/Blackwell peak and Triton leaves perf on the table, learn CuTe. Budget for the learning curve — it's not trivial, but it's the only path to FA3-class perf.

**The smell:** "We wrote this kernel in CUDA C++ for maximum perf" — in 2026, for standard matmul-family kernels, CUTLASS wraps the CUDA you'd write and adds template-level optimizations you wouldn't.

### 25. Custom Kernels Beat Vendor Libraries Only At The Margins

When hand-tuned wins: specific shapes that fall off the cuBLAS heuristic (very small batch, weird dtype combinations, fused epilogues like gelu+bias+dropout). Scott Gray's Maxwell SGEMM wasn't beating cuBLAS on all shapes — just small N where cuBLAS's heuristic picked suboptimal tiles.

For standard shapes at standard precisions, cuBLAS/cuDNN wins almost always. Write a custom kernel when you have profiled evidence the vendor path is leaving specific perf on the table for your shape and you can explain why.

### 26. CUDA Graphs Batch Launch Overhead — Until Shapes Change

CUDA graphs capture a sequence of kernel launches into a single CPU-side submission. Huge win for decode loops (hundreds of tiny kernel launches per step): on batch-1 LLM decode, launch overhead can be 20–40% of step time without graphs.

**Graphs break on dynamic shapes.** NVIDIA's own documentation: "Changing shapes means different tensor sizes, different memory allocations, and often different kernels, all of which break CUDA graph capture." MoE routing (variable tokens per expert), ragged batches, variable image sizes — graphs become a net loss because you either re-capture (expensive) or bucket (N graphs, memory bloat).

vLLM captures graphs per batch size for decode; prefix-cache topology changes break graphs. The trade is managed case-by-case in the serving engine.

**The smell:** A blog post claiming "CUDA graphs gave us 2× on training." Training graphs are usually useful only for the inner fixed-shape decode loop; your forward pass changes batch composition per step.

### 27. Triton Autotune Costs Real Time — Budget For It

`@triton.autotune` searches over tile sizes, num_warps, num_stages. Order of seconds to minutes per unique kernel-shape combination. It amortizes for repeat-call kernels; for one-shot inference, it's a tax. Modern Triton has `prune_configs_by` to cut the search space; use it.

Key trade: autotune at import time (cached) vs JIT at runtime (invisible to user). For serving stacks, pre-tune offline and commit the results.

**The signal:** Your Triton kernels have pre-tuned configs committed; autotune doesn't fire in production.

---

## §5. FlashAttention — The Canonical Kernel Fusion Case

### 28. FlashAttention Proved Exact Attention Is Memory-Bound

Tri Dao, Fu, Ermon, Rudra, Ré (arXiv 2205.14135, May 2022). The core insight: standard attention materializes the N×N softmax matrix in HBM, which is pure memory traffic for no algorithmic reason. Tile Q, K, V into SRAM-sized blocks (typically 64–128 rows per tile); compute softmax incrementally via online-softmax (Milakov & Gimelshein, 2018); never materialize N×N in HBM.

HBM accesses drop from Θ(Nd + N²) to Θ(N²d²/M) where M is SRAM size (~100 KB on A100, so d²/M ≈ 1/10 in practice). Measured: 15% speedup on BERT-large, 3× on GPT-2 (seq=1K), 2.4× on Long Range Arena. Memory O(N) not O(N²) — what enabled 16K+ context on GPUs that previously OOM'd at 2K.

**After May 2022, using vanilla softmax(QK^T/√d)V for exact attention is a bug, not a choice.**

### 29. FA2 Was A 2× Work-Partitioning Fix, Not A New Algorithm

Tri Dao, arXiv 2307.08691, July 2023. Three specific changes over FA1, none of them about memory:

1. **Hoist scaling out of the inner loop.** Non-matmul FLOPs are 16× more expensive than matmul FLOPs on A100 (because matmul uses tensor cores, scalar doesn't). Moving the `1/√d` scaling outside saves cycles that felt free but weren't.
2. **Parallelize over the sequence dim, not just batch × heads.** Crucial for long-context training where batch × heads is small.
3. **Split Q across warps within a block, not K/V.** Eliminates inter-warp shared-memory communication in softmax reduction.

225 TFLOPs/s on A100 (72% MFU end-to-end) vs FA1's 25–40% of peak. **The gap between FA1 and FA2 was a work-partitioning bug, not an algorithmic insight** — and this is the general pattern for kernel-level perf wins. The algorithm is right; the scheduling is wrong. If your hand-rolled FA clone gets 35% of peak, it's not fundamentally broken — it's just not partitioned the way FA2 is.

### 30. FA3 Needs The Hopper-Specific Features — And Asymmetric Registers

Shah, Bikshandi, Zhang, Thakkar, Ramani, Dao (arXiv 2407.08608, Jul 2024). Hopper-only. Three mechanisms stacked:

- **Warp specialization** with producer/consumer roles; producers issue TMA loads, consumers do wgmma. Async barriers sync them.
- **Interleave matmul and softmax** to hide softmax latency behind wgmma.
- **FP8 with incoherent processing** (Hadamard rotation before quantization to suppress outlier impact). FP8 numerical error 2.6× lower than baseline FP8 attention.

**740 TFLOPs/s FP16 (75% H100 utilization), ~1.2 PFLOPs/s FP8.** 1.5–2× over FA2, which topped out at ~35% H100 utilization.

**The smell:** A "Hopper-optimized" transformer kernel that uses fp16 only and doesn't warp-specialize. You're running FA2 on Hopper and calling it done; 2× is on the table.

### 31. FA Is The Pass-Fail Benchmark For "Optimized"

If a 2.7B model trains at < 150 TFLOPs/s per A100, you're not using FA. If a 70B model runs at < 400 TFLOPs/s per H100 BF16, you're not using FA3. These are pass-fail — not "suboptimal," pass-fail. Any team claiming "optimized transformer training" who can't clear these bars has shipped an unoptimized stack.

### 32. FlashAttention Loses In Specific Conditions

Not always a win:

- **Very short sequences + tiny batch inference.** Producer-consumer pipeline never fills; TMA warmup cost dominates. Measured crossover around seq=256 on H100.
- **Non-Hopper hardware.** A100/L40S can't use TMA or wgmma — FA3's gains evaporate; stay on FA2.
- **Head dim ≥ 128 with causal mask.** Per FA3 blog: FA3-FP8 is behind vanilla for those cases. FA3 decode path was weaker than FA2 initially; the split-KV + GQA inference path landed later.
- **Exotic attention patterns** the paper doesn't cover (sparse attention, sliding-window variants with non-standard stride).

The judgment: FA is correct by default, but verify on your specific shape if you're batch<4 or seq<512 — you may be paying kernel-launch overhead for no compensating win.

### 33. Flash-Decoding Adds The KV-Length Parallelization Axis

When Q-seq = 1 (decoding) and batch is small, FA1/FA2 use less than 1% of the GPU — parallelization is over batch × heads × Q-seq, and with Q=1 and batch=1 there's nothing to parallelize. Dao, Haziza, Massa, Sizov (princeton-nlp.github.io/flash-decoding, Oct 2023) added a parallelization axis over the KV cache: split KV into chunks, compute partial softmax per chunk, combine via online-softmax reduce.

**Up to 8× faster on CodeLlama-34B at long context (512 → 64K).** Attention time roughly constant up to 32K. This is the basis for nearly every long-context inference kernel since — vLLM decode, SGLang, FlashInfer, TRT-LLM paged.

**The signal:** You serve with batch < 8 and context > 4K, and you've checked that your stack uses a split-KV path.

### 34. FlexAttention Tackles The Software Lottery — With A Precision Gotcha

Horace He's FlexAttention (PyTorch blog, Aug 2024) addresses "software lottery tyranny": researchers drop architectures because no fused kernel exists (MosaicML abandoned ALiBi). FlexAttention generates a fused kernel from a user-written `mask_mod` + `score_mod`. ~90% of FA2 forward, ~85% backward; causal masking gets 2× via block sparsity. TorchTune sample packing measured 71% throughput improvement.

**Watch for precision regressions:** pytorch/pytorch#161022 — FlexAttention's default precision silently decreased from IEEE to TF32 in a release. **Never trust default precision flags across PyTorch versions.** This is a recurring PyTorch footgun (see also #153195 on the TF32 default for cuBLAS matmul).

### 35. Tri Dao's IO-Awareness Is The Framework, Not Just An Optimization

The generalizable idea from FA is broader than attention: **for any kernel, ask what you're writing to HBM that you don't need to.** Softmax materializations, K/V repeat expansions for MQA/GQA, intermediate activations that get immediately read back — all are IO-awareness candidates. The pattern repeats in every modern fused kernel: fuse what can be fused within SRAM, spill to HBM only when forced to.

Cite this framing when designing new kernels. "Data movement is the cost" (perf-judgment §55 Roofline) is the universal principle; FA's specific contribution is showing how to apply it to a kernel people thought was compute-bound.

---

## §6. Mixed Precision And Numerical Judgment

### 36. BF16 Won Over FP16 For Pretraining — But The Story Isn't Over

BF16 has FP32's 8-bit exponent (same range) and FP16's lower mantissa — no loss scaling needed for large-scale training because gradients don't underflow out of the range. FP16's 5-bit exponent runs out for LLM-scale training even with dynamic loss scaling; the instability mode is exponent overflow that loss scaling doesn't help.

Production pretraining settled on BF16 circa 2023. Meta's Llama 3.1 405B was trained in full BF16 at ~40% MFU; FP8 was used only for inference quantization (confirmed in the Llama 3 paper and ai.meta.com blog). The "FP8 everywhere at scale" narrative is overstated — frontier labs pick BF16 for pretraining when precision matters more than throughput.

**The counter-shift:** "Defeating the Training-Inference Mismatch via FP16" (arXiv 2510.26788, Oct 2025) identifies BF16's 7-bit mantissa as the root cause of RL training-inference mismatch; FP16 "virtually eliminates" it. WHEN: BF16 for pretraining long-horizon, FP16 may win for RL fine-tuning. Single paper, LOW confidence — watch for replication through 2026.

**The smell:** A new training project using FP16 with loss scaling in 2026. Unless you've read the RL-FP16 paper and have a specific reason, use BF16.

### 37. TF32 Is The Silent Default For FP32 Matmul

Ampere+ cuBLAS with default settings silently uses TF32 for "FP32" matmul — reads only the first 10 bits of the FP32 mantissa. PyTorch's default for `torch.backends.cuda.matmul.allow_tf32` has flipped between versions (#67384, #76509, #153195 in pytorch/pytorch), and users have filed "TF32 is disabled by default without warning" as a bug. `NVIDIA_TF32_OVERRIDE=0` is the sledgehammer; `torch.backends.cuda.matmul.allow_tf32 = False` is the per-session control.

**If you run an "FP32" ablation study, scientific computation, or anything where numerics are the contract, explicitly check TF32 is off.** The failure mode is quiet: your results look plausible but differ from another stack's FP32. This has burned enough teams that checking the flag is a senior-engineer reflex.

### 38. FP8 Training Is Production-Ready On Hopper — With Careful Scaling

Microsoft FP8-LM (arXiv 2310.18313, Oct 2023): GPT-175B with 39% memory reduction, 75% faster than BF16 Megatron on H100. DeepSeek-V3 (arXiv 2412.19437, Dec 2024): **671B total / 37B active MoE, trained in FP8 mixed precision on 2,048 H800s for 2.788M GPU-hours.**

The production pattern: FP8 (E4M3 forward, E5M2 backward) for most GEMMs; keep BF16/FP32 for embedding, LM head, gating, norms, attention softmax. **Blanket FP8 diverges.** Transformer Engine (NVIDIA) automates the scaling-factor bookkeeping; doing it manually is possible but error-prone.

Caveat: DeepSeek-V3's FP8 MFU of 21.4% converts to ~42.9% BF16-equivalent, comparable to Llama 3's ~40% BF16. The headline "trained for $5.6M" reflects FP8 savings + MoE architecture, not a magical efficiency leap. Vendor-reported; external audit absent.

### 39. FP8 Breaks Silently At 220B Tokens On SwiGLU

"Scaling FP8 training to trillion-token LLMs" (arXiv 2409.12517, 2024): Llama2-7B FP8 training diverged at 220B tokens from SwiGLU-amplified outliers. The failure mode is invisible in shorter FP8 studies. Fix: Smooth-SwiGLU modification that suppresses outliers.

WHEN: long-horizon FP8 training with SwiGLU (i.e., nearly every modern LLM). If your FP8 ablation is 20B tokens and looks fine, you have no evidence it's fine at 500B. Budget for the switch back to BF16 or the Smooth-SwiGLU workaround.

**The smell:** A "successful FP8 training" claim from a < 100B-token run. Measure at 300B+ or you don't know.

### 40. FP4 On Blackwell Is Inference-Only

NVFP4 (Blackwell feature, 2024–2025) delivers 8×B200 at ~98,858 tok/s on Llama2-70B MLPerf offline — 2.8× over 8×H200. DeepSeek-R1 FP8→FP4 PTQ: MMLU drops 0.1% (90.8 → 90.7); AIME 2024 actually +2%. **Inference-ready for 70B+ models in 2026.**

**Don't do FP4 training.** Not yet viable. DeepSeek's FP8 work was 2+ years after FP8-LM; FP4-training viability is probably ~2027, and you don't want to bet a training run on unproven numerics.

### 41. FP8 Is Not A Free 2×

TorchAO measurements on Llama3 8B/8×H100: 1.25× over BF16 with tensor-wise scaling. At 405B on 512 H100: 1.5×. At 70B on 1920 H200 with row-wise scaling: 1.43×. The theoretical 2× compute win is clipped because:

1. You become compute-bound at FP8 throughput before fully amortizing the bandwidth win on weights.
2. Scaling overhead (per-tensor or per-row) adds kernels.
3. The non-FP8 parts of the graph (norms, embedding, LM head) don't shrink.

Budget 1.25–1.5× end-to-end when planning FP8 capacity. If someone promises 2×, they're quoting a kernel micro-benchmark, not end-to-end training.

---

## §7. Quantization For Inference

### 42. AWQ Won The 4-Bit Quality War; GPTQ-Marlin Wins 4-Bit Decode Throughput

**GPTQ** (Frantar, Ashkboos, Hoefler, Alistarh, arXiv 2210.17323, ICLR 2023): one-shot PTQ using approximate second-order info (Hessian-based). 3–4 bits with "negligible" perplexity degradation on OPT/BLOOM 175B. Fits 175B on a single A100 80GB; decode 3.25× on A100 with a tuned kernel.

**AWQ** (Lin et al., arXiv 2306.00978, MLSys 2024): activation-aware channel scaling. Identify salient weight channels by activation magnitude (~1% of weights); scale up before quantization (equivalent transform). No backprop, no reconstruction — just calibration statistics. Faster to quantize (~10–30 min for 7B vs hours for GPTQ), fewer calibration samples (128–512 vs 2048+), generalizes better to instruction-tuned and multimodal models.

Quality: AWQ ~95% retention vs GPTQ ~90% at 4-bit on MMLU. Decode throughput with Marlin kernels: Marlin-AWQ at 741 tok/s vs vanilla AWQ at 68 tok/s; Marlin-GPTQ at 712 tok/s, 2.6× over vanilla GPTQ. **Kernel choice matters more than quant scheme.**

Rule of thumb: AWQ when quality is the priority (instruction-tuned chatbots, multi-task serving); GPTQ-Marlin when throughput is the priority (single-task high-volume). HuggingFace's evaluator and Red Hat's 500K-eval study (Oct 2024) both favor AWQ on quality.

**The smell:** A 4-bit serving benchmark in 2026 not using Marlin kernels. You're comparing 10× stale numbers.

### 43. GPTQ Collapses At 2-Bit, AWQ Survives

arXiv 2402.16775: "Under extreme 2-bit quantization conditions, the performance of GPTQ collapses entirely." AWQ's activation-aware approach preserves the salient channels; GPTQ's Hessian-based weight-only approach does not. For sub-4-bit weight quant on instruction-tuned models, use AWQ or newer schemes (QuaRot, SpinQuant), not GPTQ.

### 44. Smaller Models Quantize Worse — The "4-Bit Is Free" Claim Is Scale-Dependent

Red Hat's 500K-eval study (developers.redhat.com, Oct 2024): "Larger models generally handle quantization better than smaller ones." The "no quality loss" claim comes from 70B+ benchmarks; < 7B at 4-bit degrades measurably on instruction-following and reasoning evals.

WHEN: 70B at 4-bit is usually fine for chat quality. 7B at 4-bit is lossy enough that you may regret it for instruction-following. Check your specific model class on your specific eval before committing.

### 45. LLM.int8() Established The 6.7B Phase Shift

Dettmers, Lewis, Belkada, Zettlemoyer (NeurIPS 2022, arXiv 2208.07339). At ≥ 6.7B params, systematic outlier features emerge in a small set of hidden dimensions with ~100× normal-value magnitudes. Vanilla per-tensor int8 destroys them; perplexity collapses. Fix: mixed-precision decomposition — outlier feature dims go through fp16 matmul (~0.1% of values), rest through int8. No perplexity loss on OPT-175B.

Key judgment: **"naive int8 breaks at scale" is a predictable phenomenon, not a tuning issue.** Dettmers' "emergent features" framing: "The phase shift happens around 6.7B, where 100% of layers use the same dimension for outliers." Below 6.7B, some layers don't even have the problem. This is the foundation for bitsandbytes-level 8-bit inference and predicts why simple int8 schemes work on 1B models but break at 13B+.

### 46. SmoothQuant Fixes Outliers Structurally, Not By Carving Them Out

Xiao, Lin, Seznec, Wu, Demouth, Han (ICML 2023, arXiv 2211.10438). Insight: activations have outliers (hard to quantize); weights are smooth (easy). Migrate quantization difficulty by the transform Y = (X/s) · (s·W) — per-channel scale factor s moves the outlier mass from activations to weights. Enables W8A8 with per-tensor static scales, no retraining.

1.56× speedup, 2× memory reduction vs FP16. Preserves accuracy across OPT, BLOOM, GLM, Llama, Falcon, Mistral families. Any W8A8 runtime (TensorRT-LLM, FasterTransformer, vLLM's INT8) uses this pattern. Cite when someone asks "why can't we just quantize activations directly?" — SmoothQuant is the answer.

### 47. KV Cache Quantization Has A Different Quality Cliff

Pre-RoPE key outliers are a distinct failure mode from weight quantization. KVQuant (arXiv 2401.18079): "Existing quantization solutions fail to represent KV cache activations accurately in sub-4-bit precision... quantization to even lower bits can lead to substantial accuracy drops." The fix: per-channel key quantization + pre-RoPE key quant — splitting the K projection into its outlier-prone (pre-RoPE) and tractable (post-RoPE) regimes.

Don't assume "4-bit weights work → 4-bit KV works." They're different problems. And **weight + KV quant stacked is 3× SLOWER, not faster** (HuggingFace KV cache blog) — dequant cost dominates when both are naively applied.

### 48. QLoRA's "Match Full Fine-Tune Quality" Is Overstated

Dettmers' QLoRA (arXiv 2305.14314, May 2023) enables 65B fine-tune on a 48 GB GPU via NF4 (information-theoretically optimal 4-bit for N(0,1) weights), double quantization (quantize the scales), and paged optimizers. Revolutionary for local fine-tuning.

**Honest numbers (Modal's retro, 2024):** QLoRA recovers 80–90% of full fine-tune quality; LoRA recovers 90–95%. Full fine-tune retains advantage on "math, programming" — complex reasoning domains. The "as good as FFT" claim in the abstract is marketing; the gap is real on code/math evals. Use QLoRA for chat fine-tunes where quality has headroom; use LoRA or FFT for code/math.

### 49. BitNet b1.58 Is Research-Stage, Not Production

Microsoft's BitNet b1.58 (arXiv 2402.17764, Feb 2024): ternary weights {−1, 0, +1}, trained from scratch with QAT. Claims FP16-matching perplexity at 3B+ with 2.71× speedup, 3.55× less memory. Microsoft released 2B4T weights (arXiv 2504.12285, Apr 2025) with a bitnet.cpp runtime showing 1.37–5.07× speedup on ARM CPUs.

**No independent large-scale (> 7B) replication.** Single research lab. The CPU-efficiency numbers are real; the perplexity-matching claim at frontier scale is unverified externally. Don't bet production on 1.58-bit at > 10B until a second lab reproduces.

**The signal:** You can name the quant scheme, the kernel (Marlin, cuDNN, cuBLASLt FP8), the quality eval (MMLU, HumanEval, not just "looks fine"), and the cliff condition (model size, task type) — not just "we use 4-bit."

---
