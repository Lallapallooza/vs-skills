# IBS (Instruction-Based Sampling) Mechanics

AMD's IBS is the precise-sampling facility on Zen. It is the feature most often misunderstood, misattributed in reports, and mis-interpreted by users of profilers that expose it. This reference is the load-bearing knowledge for correctly using and reading IBS data.

## What IBS is

Two independent, per-core hardware samplers on every Zen CPU:

- **IBS Fetch** samples the *front-end*: which instruction cache line was fetched, whether it hit the icache / iTLB / L2 / ITLB walker, fetch latency, and the fetch linear address.
- **IBS Op** samples the *back-end*: a dispatched macro-op, the retired IP, data-cache hit/miss, dTLB status, DataSrc (where the data came from), load/store physical and linear addresses, cache-miss latency, branch target.

Both are random samplers with a software-programmable period. MSRs:

- `IBS_FETCH_CTL 0xc001_1030` — fetch sampler control
- `IBS_FETCH_LINADDR 0xc001_1031`
- `IBS_FETCH_PHYSADDR 0xc001_1032`
- `IBS_OP_CTL 0xc001_1033` — op sampler control
- `IBS_OP_RIP 0xc001_1034`
- `IBS_OP_DATA 0xc001_1035`
- `IBS_OP_DATA2 0xc001_1036`
- `IBS_OP_DATA3 0xc001_1037`
- `IBS_DC_LIN_ADDR 0xc001_1038`
- `IBS_DC_PHYS_ADDR 0xc001_1039`
- `IBS_BR_TARGET 0xc001_103B` (Fam 19h+)

Linux exposes these through `perf_event_open` as the `ibs_op` and `ibs_fetch` PMUs (`/sys/bus/event_source/devices/ibs_{op,fetch}/`). Kernel source: [arch/x86/events/amd/ibs.c](https://github.com/torvalds/linux/blob/master/arch/x86/events/amd/ibs.c). Bitfield definitions: [arch/x86/include/asm/amd/ibs.h](https://github.com/torvalds/linux/blob/master/arch/x86/include/asm/amd/ibs.h).

## Tagging contract (IBS Op)

1. Software writes `OpMaxCnt` to `IBS_OP_CTL` (period, in ops or cycles).
2. Hardware counts in the background; when `OpCurCnt` hits zero, the *next dispatched macro-op* is tagged.
3. The tagged op flows through the out-of-order machine normally.
4. On retire, hardware latches the tagged op's state to `IBS_OP_DATA{,2,3}` + `IBS_OP_RIP` and fires an NMI.
5. The NMI handler reads the MSRs, emits a perf sample, clears `IBS_OP_VAL`, and re-arms.

**Period semantics (`cnt_ctl` bit in `IBS_OP_CTL`):**
- `cnt_ctl=0` → counter decrements per *clock cycle*. Gated by halt — halted cycles don't count.
- `cnt_ctl=1` → counter decrements per *dispatched op*. AMD-recommended; less biased by frequency and stalls.

In `perf record -e ibs_op/cnt_ctl=1/ -c 250000`, the `-c 250000` is the period.

## Precision contract (the most important slide)

**IP is precise. Count is not.**

- The RIP written to `IBS_OP_RIP` is the architectural RIP of the tagged, retired macro-op. Zero skid. `PERF_EFLAGS_EXACT` is set by the kernel.
- The *counter value* at sample time is not exact. There is a time gap between NMI fire and the handler disabling the counter, during which more events accumulate. This is a fundamental difference from Intel PEBS, which freezes the counter before NMI delivery.

**Practical consequence:**

- Use IBS to answer **where** questions: "which line / function / instruction is the top contributor to this metric?"
- Do not use IBS to answer **how many** questions unless you are comfortable with single-digit-percent error bars and have cross-checked against a regular PMC count.

**Source:** [Sasongko, Chabbi, Kelly, Unat. "Precise Event Sampling on AMD Versus Intel: Quantitative and Qualitative Comparison," IEEE TPDS 2023](https://ieeexplore.ieee.org/document/10068807/).

## Abort and speculation

IBS Op tags macro-ops at *dispatch*. The sample is recorded only on retire. Therefore:

- Ops that are **aborted** (faulted, flushed due to branch misprediction, wrong-path, etc.) are **silently dropped** — no sample is recorded for them.
- Wrong-path / speculative work is **invisible** to IBS Op.

If you are hunting misprediction *cost* (how much work gets thrown away), IBS Op will under-report. Use instead:
- Zen 4+ TMA `bad_speculation` bucket (sees dispatch-level activity, including wrong-path).
- PMC ratios: `ex_ret_brn_misp / ex_ret_ops` for mispredict rate; or
- LBR V2 (Zen 4+) to capture the mispredicted branch chain.

## Sample loss / coalescing

There is no hardware "dropped IBS sample" counter. If the NMI handler is slow relative to the sample rate, multiple ops finish between NMIs; the handler sees only the latest. Detect by:

```bash
# Compare observed sample count to expected (period-based)
duration_ns=$(( <expected_run_ns> ))
period=250000
cores=$(nproc)
# Expected samples ≈ (core_cycles × cores / period)  for cnt_ctl=0
# If actual samples are <<expected, NMI is dropping
```

Or more empirically: increase period (e.g., 1e6 → 1e7) and check if hotspot attribution changes significantly. If it does, your previous rate was too aggressive.

## Which ops are eligible

- Any macro-op at dispatch. IBS does not discriminate by op type by default.
- Micro-op fusion: the tag attaches to a *macro-op*, which may be decoded to 1-2 micro-ops. There is no per-micro-op attribution.
- Microcoded flows: marked with `op_microcode` bit in `IBS_OP_DATA`. These are complex sequences (e.g., some string instructions) — the sample represents the macro-op boundary, not individual steps.
- Fused branch ops: marked with `op_brn_fuse` in `IBS_OP_DATA`.

## Per-generation capability matrix

| Feature | Zen 2 | Zen 3 | Zen 4 | Zen 5 | Zen 6 (preview) |
|---|---|---|---|---|---|
| IBS Op | ✓ | ✓ | ✓ | ✓ | ✓ |
| IBS Fetch | ✓ (but samples very low) | ✓ | ✓ | ✓ | ✓ |
| `OpMaxCnt` width | 20 bits (max 2^20) | 20 bits | 27 bits (`opmaxcnt_ext`) | 27 bits | 27 bits |
| `L3MissOnly` filter | ✗ | ✗ | **✓** (Zen 4+) | ✓ | ✓ |
| Extended DataSrc (local vs remote-CCX vs remote-socket) | partial | partial | extended | extended | + remote-socket flag |
| `LdLat` threshold filter (128–2048 cy) | ✗ | ✗ | ✗ | **✓** (Zen 5+) | ✓ |
| `IBS_BR_TARGET` MSR | ✗ | ✓ (Fam 19h+) | ✓ | ✓ | ✓ |
| `ibsop-l3miss` / `ibsfetch-l3miss` shortcuts | n/a | n/a | ✓ | ✓ | ✓ |
| Fetch-latency threshold filter | ✗ | ✗ | ✗ | ✗ | ✓ (Zen 6 preview) |
| Streaming-store filter | ✗ | ✗ | ✗ | ✗ | ✓ (Zen 6 preview) |

**Zen 1/Zen 2 IBS Fetch limitation:** uProf 4.1 and 5.x both list this in the known-limitations page: "On Linux, IBS Fetch profiling shows extremely low number of samples on AMD 'Zen1 and Zen2' generation processors." If targeting EPYC 7002 (Rome) or Ryzen 3000, use IBS Op for front-end analysis too, or skip IBS Fetch and use PMC events directly.

## DataSrc field (IBS Op)

The `IBS_OP_DATA2` register encodes where a load obtained its data. Values (Zen 4+, from `amd-ibs.h` and AMD PPR):

| DataSrc value | Meaning |
|---|---|
| `0x1` | Local L3 / same-CCD cache hit |
| `0x2` | Local DRAM |
| `0x3` | Remote (far) DRAM |
| `0x4` | Remote CCX / different CCD on same socket |
| `0x5` | Remote-socket cache |
| `0x7` | Reserved / other |

Additional bits:
- `rmt_node` (remote NUMA node)
- `remote_socket` (Zen 6+ distinguishes far socket)

On Zen 2/3 the DataSrc encoding is coarser (local vs. other); Zen 4 expanded it to distinguish local-CCD, remote-CCD, remote-socket. Correct attribution of memory bottlenecks on chiplet EPYCs depends on this field.

## Scoping limitations

- **Per-process scoping is NOT supported** for IBS. It is a hardware-global sampler. The kernel opens `ibs_op` with `CAP_SYS_ADMIN` or `CAP_PERFMON` required; `perf_event_paranoid <= 0` is effectively mandatory.
- **Per-cgroup / per-container scoping is NOT supported.** On cloud or Kubernetes, IBS samples include all activity on the core. Filter in post-processing by PID.
- **Virtualization:** IBS is supported in KVM guests only with paravirtualized PMU; pass-through works on recent kernels. Nested virt and some cloud hypervisors disable IBS. Documented cases: AWS and Azure EPYC instances have per-provider caveats — test with a canary.

## Reading IBS samples via perf

```bash
# IBS Op, period 250k dispatched ops, with dwarf callstacks
perf record -e ibs_op/cnt_ctl=1/ -c 250000 --call-graph dwarf -g -- ./app

# IBS Fetch, period 250k fetch events
perf record -e ibs_fetch// -c 250000 --call-graph dwarf -g -- ./app

# L3 miss only (Zen 4+)
perf record -e ibs_op/l3missonly=1,cnt_ctl=1/ -c 100000 -- ./app

# Report
perf report --stdio -i perf.data
perf script -F ip,sym,dso,period,brstack  # raw samples with extra IBS fields

# AMD's RFC scripts for IBS metrics (when in your perf tree)
perf script report amd-ibs-op-metrics
perf script report amd-ibs-fetch-metrics
```

Source: [patchew.org — Ravi Bangoria (AMD) RFC Jan 2025](https://patchew.org/linux/20250124060638.905-1-ravi.bangoria@amd.com/).

## Reading IBS samples via uProf

```bash
# uProf's preset (assembles IBS Op + IBS Fetch plus metadata)
AMDuProfCLI collect --config ibs -g --use-linux-perf -o out ./app

# Report top functions by IBS samples
AMDuProfCLI report -i out/*.ses -f csv -o ibs.csv
```

In the GUI, the "Analyze > IBS" tab provides per-function and per-line IBS breakdowns, including DataSrc-classified memory access attribution.

## Common mistakes

1. **Quoting IBS sample counts as hard numbers.** They are not exact. Use them to rank, not to budget.
2. **Combining IBS with TBP/EBP events in one custom config.** uProf silently drops samples (documented 5.x bug). Run IBS alone or with AMD-provided configs.
3. **Using IBS Fetch on Zen 1/2.** Sample rate is pathologically low. Use IBS Op for front-end questions on those generations.
4. **Expecting per-process IBS.** Samples cover the entire core; filter by PID in post-processing.
5. **Interpreting aborted-op absence as "no activity."** Wrong-path work is invisible to IBS Op. Use TMA `bad_speculation` or PMC mispredict ratios to see it.
6. **Ignoring the generation.** `L3MissOnly` on Zen 3 silently fails; `LdLat` on Zen 4 silently fails. Always check the capability matrix.
7. **Using `cnt_ctl=0` (cycles) when the workload has heavy sleeps / blocking I/O.** The sampler doesn't tick when the core halts; you'll get biased attribution toward CPU-bound regions. Use `cnt_ctl=1` (op-based) when unsure.

## When NOT to use IBS

- The workload has known-high misprediction rate and you care about mispredict cost → use TMA + mispredict PMC ratios.
- You need exact counts of a specific event (e.g., exact cache-miss count) → use regular PMCs via `perf stat`.
- You're profiling a short workload (<1 s) — IBS sample counts will be too low to be useful. Either extend the workload or use a lower period (e.g., `-c 50000`).
- You need per-cgroup scope (Kubernetes) → use `perf record -e cpu-cycles` with `--cgroup`. Lose precision, gain scope.

## References

- [Drongowski, "Instruction-Based Sampling: A New Performance Analysis Technique for AMD Family 10h Processors" (2007)](https://www.amd.com/content/dam/amd/en/documents/archived-tech-docs/white-papers/AMD_IBS_paper_EN.pdf) — canonical whitepaper
- [Sasongko et al., TPDS 2023 — PEBS vs IBS comparison](https://ieeexplore.ieee.org/document/10068807/)
- [perf-amd-ibs(1) man page](https://man7.org/linux/man-pages/man1/perf-amd-ibs.1.html)
- [Linux kernel arch/x86/events/amd/ibs.c](https://github.com/torvalds/linux/blob/master/arch/x86/events/amd/ibs.c)
- [Linux kernel arch/x86/include/asm/amd/ibs.h (MSR bitfields)](https://github.com/torvalds/linux/blob/master/arch/x86/include/asm/amd/ibs.h)
- [AMD Zen 6 IBS improvements preview — Phoronix](https://www.phoronix.com/news/Linux-Perf-AMD-IBS-Zen-6)
- [reflexive.space — Zen 2 IBS experiments](https://reflexive.space/zen2-ibs/)
- [AMD IBS Toolkit (Greathouse, simplified char-device interface)](https://github.com/jlgreathouse/AMD_IBS_Toolkit)
