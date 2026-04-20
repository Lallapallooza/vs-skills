# Top-Down Microarchitecture Analysis (TMA) on AMD Zen

TMA (sometimes TMAM — Top-Down Method for Analysis of Microarchitecture) is the methodology for categorizing a workload into four buckets — *Retiring*, *Bad Speculation*, *Frontend Bound*, *Backend Bound* — then drilling into the largest bucket. It's the right first question for "is this bottlenecked in the CPU, and where?"

The methodology is Yasin's (Intel, ISPASS 2014); AMD's implementation on Zen 4+ is a faithful application of the same principles, with different formulas and counter names.

## When you can use it

- **Zen 4+**: full Level-1 + Level-2 TMA via uProf's `assess` config or hand-built perf metric groups. Linux kernel ships `tools/perf/pmu-events/arch/x86/amdzen4/pipeline.json` with the authoritative formulas.
- **Zen 3**: cycle-based accounting only; no dispatch-slot counters to drive the proper formula. Can approximate via `ex_ret_ops` per cycle, but not the full bucketing. uProf's `assess` on Zen 3 gives a cruder overview.
- **Zen 2**: same as Zen 3 — no proper TMA. Use individual PMC ratios for targeted questions.
- **Zen 1**: even cruder. Skip TMA; go straight to PMC ratios.

Source: [Linux amdzen4 pipeline.json](https://patchew.org/linux/20221214082652.419965-1-sandipan.das@amd.com/) (authored by Sandipan Das @ AMD, imported Linux 6.2).

## Level-1 formulas (Zen 4)

```
total_dispatch_slots = 6 * ls_not_halted_cyc                              # 6-wide dispatch
retiring             = ex_ret_ops                   / total_dispatch_slots
frontend_bound       = de_no_dispatch_per_slot.no_ops_from_frontend / total_dispatch_slots
backend_bound        = de_no_dispatch_per_slot.backend_stalls       / total_dispatch_slots
smt_contention       = de_no_dispatch_per_slot.smt_contention       / total_dispatch_slots
bad_speculation      = 1 - retiring - frontend_bound - backend_bound - smt_contention
```

The four buckets + SMT contention sum to 1.0. They represent where each dispatch slot went:

- **Retiring**: slot issued a useful micro-op that retired. Good unless very low.
- **Frontend Bound**: frontend (fetch/decode) did not supply a micro-op. Investigate icache, iTLB, branch prediction, decoder bandwidth.
- **Backend Bound**: frontend supplied, but backend (execution ports, ROB, scheduler, registers, load-store queue) wasn't ready. Investigate execution resources, data cache, register pressure.
- **Bad Speculation**: slot was used but the work was thrown away. Investigate branch misprediction, memory ordering violations, pipeline flushes.
- **SMT Contention** (uniquely broken out on AMD): slot unavailable because the SMT sibling consumed it. Means SMT is active contention, not a category of work loss.

## Level-1 formulas (Zen 5)

```
total_dispatch_slots = 8 * ls_not_halted_cyc     # 8-wide dispatch (CHANGED from 6)
```

Otherwise the structure is the same. **Always verify against the `amdzen5/pipeline.json` on the target kernel** — AMD may add events or change event names between minor kernel versions.

## Level-2 buckets

From the same `pipeline.json`:

**Frontend Bound** → two sub-categories:
- `frontend_bound_latency` — frontend supplied 0 ops that cycle (iTLB/icache miss, branch prediction restart, decoder cold).
- `frontend_bound_bandwidth` — frontend supplied <6 (or <8 on Zen 5) ops (decode bandwidth limit, small loop buffer utilization).

**Backend Bound** → two sub-categories:
- `backend_bound_memory` — retire blocked by incomplete load / store buffer full. Drill into: dcache miss, dTLB miss, DRAM latency, cache coherence traffic.
- `backend_bound_cpu` — ROB / scheduler / register file / integer or FP execution port saturated. Drill into: port-specific counters (limited on AMD vs Intel; see Abel & Reineke 2024).

**Bad Speculation** → two sub-categories:
- `mispredicts` — work discarded due to branch misprediction.
- `pipeline_restarts` — work discarded due to a machine clear (self-modifying code, memory ordering violations, microcode assists).

## Counter budget

TMA Level-1 needs 4 metrics (slots via cycles, retired ops, frontend stalls, backend stalls) — fits a single 4-event group on Zen's 6 GP PMCs → **no multiplexing, results are exact within IBS/count-imprecision bounds**.

TMA Level-2 expands to ~12 events → **exceeds 6 counters** → kernel multiplexes → results scaled by `%enabled`. Multiplexing scaling assumes uniform activity distribution across the rotation interval. On bursty workloads (phased: CPU-bound → memory-bound → CPU-bound) this assumption breaks and Level-2 percentages become imprecise.

**Workaround for accurate Level-2:** either (a) run the workload twice with disjoint Level-2 event sets and merge, or (b) use uProf's `assess_ext` config which internally uses pre-curated event groups, or (c) pin `--mux-interval 100` (default) and accept some scaling error.

## Running TMA

### Via uProf (Zen 4+)

```bash
AMDuProfCLI collect --config assess -g --use-linux-perf -o ./tma ./app
AMDuProfCLI report -i ./tma/*.ses -f csv -o tma.csv

# Extended Level-2
AMDuProfCLI collect --config assess_ext -g --use-linux-perf -o ./tma_ext ./app
```

Read the `Pipeline Utilization` table. Columns are the four Level-1 + SMT contention fractions, per-function.

### Via plain perf (Zen 4+ with `pipeline.json` in kernel)

```bash
# Linux 6.2+ with amdzen4 event files
perf stat -e "{cycles,instructions,ex_ret_ops,ls_not_halted_cyc,de_no_dispatch_per_slot.no_ops_from_frontend,de_no_dispatch_per_slot.backend_stalls,de_no_dispatch_per_slot.smt_contention}" -- ./app
```

Or use the pre-curated metric groups (if perf ships them):
```bash
perf stat --topdown -- ./app               # may or may not work on AMD depending on kernel
perf stat -M TopdownL1 -- ./app            # explicit Level-1 metric group
perf stat -M TopdownL2 -- ./app            # Level-2
```

### Via LIKWID (for scripted / HPC reproducibility)

LIKWID group files (e.g., `TMA-L1` on Zen 4) run a 4-event group and emit the same breakdown. Per-region measurement via `LIKWID_MARKER_*` macros in source.

```bash
likwid-perfctr -C 0-15 -g TMA_L1 -m -- ./app
```

## Interpretation

**Rule of thumb for "what to fix":**

| Dominant bucket | Typical fix |
|---|---|
| Retiring > 60-70% | You're compute-bound. Look at IPC, SIMD throughput, algorithmic choice. TMA can't tell you more; move to IPC/FLOPS analysis. |
| Frontend Bound (latency) | iTLB or icache misses, branch prediction restarts. Try huge pages for text, align hot loops, reduce indirect branches. |
| Frontend Bound (bandwidth) | Decoder can't supply enough ops. Unroll / simplify hot loops; check micro-op cache utilization (Zen 4+ has dedicated events). |
| Backend Bound (memory) | Load-queue full, dcache miss, store buffer full. Prefetch, restructure data layout, consider DataSrc to see where loads hit. |
| Backend Bound (CPU) | Execution port saturation, ROB full. Reduce long-latency chains, break dependency chains. Harder to fix without asm-level changes. |
| Bad Speculation | Unpredictable branches, memory ordering. Branch-reduce (branchless where predictor is wrong), avoid false-sharing-induced clears. |
| SMT Contention | Siblings on the same physical core are fighting. Pin workload to one thread per core, or accept SMT overhead. |

See `vs-core-_shared/prompts/language-specific/perf-judgment.md` §3 (principles 13-24) for the general performance judgment on TMA category → fix family.

## Intel VTune / pmu-tools comparisons

- **Intel VTune** on AMD: VTune runs but its TMA model is Intel-calibrated — numbers are wrong on Zen. Don't use VTune for TMA on AMD.
- **pmu-tools / toplev**: [explicitly Intel-only](https://github.com/andikleen/pmu-tools/wiki/toplev-manual). No AMD support planned.
- **No open-source AMD TMA tool besides uProf and hand-rolled perf groups.** LIKWID has group files; perf has `amdzenN/pipeline.json`. That's the universe.

AMD has no drop-in equivalent of Intel's "Microarchitecture Exploration" one-click in VTune; uProf's `assess` config is the closest.

## Worked example: frontend-bound JIT

```
Retiring:          18.3%
Frontend_Bound:    54.7%
  Frontend_Latency:  42.1%
  Frontend_Bandwidth: 12.6%
Backend_Bound:     12.4%
Bad_Speculation:   10.8%
SMT_Contention:     3.8%
```

Diagnosis: frontend-latency dominates. Likely causes:
1. iTLB misses on large code footprint (JIT engines hit this — try huge pages for the code segment).
2. icache misses due to poor code layout (profile-guided optimization / LTO may help).
3. Branch target predictor pressure (many indirect branches — consider devirtualization or inline caches).

Next step: drill into `bp_l1_tlb_miss_l2_tlb_hit` / `bp_l1_tlb_miss_l2_tlb_miss` for iTLB, `ic_fw32` / `ic_fetch_stall` for icache, and BPU-specific events for mispredicts.

## Worked example: memory-bound scan

```
Retiring:          24.1%
Frontend_Bound:     5.2%
Backend_Bound:     57.3%
  Backend_Memory:   49.8%
  Backend_CPU:       7.5%
Bad_Speculation:    3.6%
SMT_Contention:     9.8%
```

Diagnosis: backend-memory dominates. Running IBS Op with L3MissOnly filter will tell you *which lines* cause the misses; running `amd_umc_*/umc_cas_cmd.all/` will tell you *how much bandwidth* the workload needs.

Next step:
```bash
# Line-level attribution
AMDuProfCLI collect -e event=IBS_OP_L3MISS,interval=50000 -g --use-linux-perf -o ./l3m ./app

# Bandwidth quantification
sudo AMDuProfPcm -m memory -a -d 30 -o bw.csv -- ./app

# Consider: NPS mode, prefetch behavior, access pattern streaming vs random
```

## Gotchas

1. **Dispatch-width constant.** Zen 4 = 6, Zen 5 = 8. Hardcoded recipes break silently on generation change.
2. **Multiplexing scaling on Level-2.** Bursty workloads violate the uniform-distribution assumption. Use Level-1 for precise numbers.
3. **`ls_not_halted_cyc`** counts core (unhalted) cycles, not wall-clock cycles. If the workload has significant idle time, `total_dispatch_slots` will be much smaller than `wallclock_ns * clock`.
4. **SMT Contention is not a fix target.** It tells you the physical core is shared; the remedy is scheduling, not code.
5. **TMA percentages don't directly predict speedup from fixes.** A workload that is 50% Frontend-Bound won't necessarily speed up 50% from perfect frontend optimization — Amdahl's law and cross-category interactions apply. See also Coz (Curtsinger & Berger, SOSP 2015) for why "where time is spent" ≠ "where speedup helps."
6. **Zen 4 vs Zen 4c** (Bergamo): same family but with narrower cores and denser CCX — the event formulas are still the Zen 4 ones, but per-core perf is different. TMA is valid; IPC and retiring-fraction thresholds differ.

## References

- [Yasin, "A Top-Down Method for Performance Analysis and Counters Architecture," ISPASS 2014](https://www.semanticscholar.org/paper/A-Top-Down-method-for-performance-analysis-and-Yasin/6776ff919597ca4feccd413208dedc401f6e655d) — foundational methodology
- [AMD Sandipan Das Zen 4 pipeline.json patchset (Linux 6.2)](https://patchew.org/linux/20221214082652.419965-1-sandipan.das@amd.com/20221214082652.419965-4-sandipan.das@amd.com/)
- [Linux tools/perf/pmu-events/arch/x86/amdzen4/pipeline.json](https://github.com/torvalds/linux/blob/master/tools/perf/pmu-events/arch/x86/amdzen4/pipeline.json)
- [Linux tools/perf/pmu-events/arch/x86/amdzen5/pipeline.json](https://github.com/torvalds/linux/tree/master/tools/perf/pmu-events/arch/x86/amdzen5)
- [Chips and Cheese — Zen 5 at Hot Chips 2024](https://chipsandcheese.com/p/discussing-amds-zen-5-at-hot-chips-2024)
- [pmu-tools toplev manual (Intel-only, confirmation)](https://github.com/andikleen/pmu-tools/wiki/toplev-manual)
- [Abel & Reineke, "Explainable Port Mapping Inference with Sparse Performance Counters for AMD's Zen Architectures" (2024)](https://arxiv.org/html/2403.16063) — workaround for AMD's absent per-port counters
- [Denis Bakhvalov — easyperf.net TMA chapters](https://easyperf.net/) — practitioner tutorials
