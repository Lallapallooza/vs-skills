---
name: vs-core-profile-amd
description: CPU profiling on AMD Zen processors, uProf-centric with perf/samply/likwid/bpftrace as first-class complements. Use when the user wants to profile, benchmark, or microarch-analyze native code (C/C++/Rust/Go) on AMD Ryzen/EPYC hardware. Also use when the user says "uprof", "AMDuProf", "IBS", "Instruction-Based Sampling", "Zen PMU", "amd profile", "AMD timechart", "AMDuProfPcm", "roofline on AMD", "profile on Ryzen", "profile on EPYC", "zen 4 tma", "amd top-down", or asks about AMD-specific counter events, cache/branch/TLB/memory-bandwidth/power measurement on Zen.
---

# AMD CPU Profiling

Operational guide for profiling native code on AMD Zen 2/3/4/5 processors. Covers AMD uProf (CLI + PCM + timechart), Linux `perf` with AMD-specific events (IBS), `likwid` with Zen event groups, and `bpftrace`/`samply`/`hotspot` as ecosystem complements. References in this skill are Zen-generation-aware — ignoring the generation gives silently wrong results.

## Core principle: match tool specialization to the question

Prefer the most specialized tool for the specific question, not the most general one. On AMD this splits two ways:

- **AMD-specific microarch** (TMA on Zen 4+, IBS Op/Fetch with AMD filters like `L3MissOnly` / `LdLat`, per-UMC memory bandwidth, roofline, per-core power/thermal timechart) → **AMD uProf / AMDuProfPcm**. No perf-based workflow gives equivalent pre-curated output; this is where uProf earns its install. If it's available, use it for these questions.
- **Everything else** — generic hotspot hunting, cgroup-scoped profiles, off-CPU / blocked time, false sharing (`perf c2c`), HPC region markers, sharing profiles with teammates — → **perf / samply / bpftrace / likwid**. "On AMD hardware" does NOT automatically mean "use the AMD-branded tool." For a pure hotspot hunt, `perf record` + `samply` is lower friction and teammates don't need uProf installed to open the result.

The decision table below encodes this pairing. When in doubt, pick the tool whose specialization matches the question's specialization — reach for uProf *because* the question is AMD-microarch-specific, not because the CPU is AMD.

## When to use this skill

Invoke on any profiling task where the target hardware is AMD (Ryzen or EPYC). Specifically:

- Hotspot attribution in a native binary (C/C++/Rust/Go) on Zen.
- Microarchitectural bottleneck categorization (frontend/backend/bad-spec/retiring — Zen 4+ only).
- Memory-bandwidth / cache / NUMA investigation on Zen chiplet topology (per-CCD L3, cross-CCD/socket traffic).
- Power/thermal/frequency timeline during a workload.
- AMD-specific precise sampling (IBS Op / IBS Fetch) with filters like `L3MissOnly` (Zen 4+) or `LdLat` (Zen 5+).

**Do NOT use this skill for:**

- GPU profiling (AMD ROCm or NVIDIA CUDA — different skill/tooling).
- General performance-engineering *judgment* (what to optimize, when) — that lives in `vs-core-_shared/prompts/language-specific/perf-judgment.md`. This skill is the tool-mechanics companion.
- Pure Python / JavaScript profiling (use `py-spy`/`memray`/`scalene` and the appropriate language judgment file). Exception: native libraries called from Python (NumPy, PyTorch, native extensions) — those ARE AMD CPU code and this skill applies.

## Before doing anything: environment check

Profiling on AMD is unforgiving about environment. Run these once per session:

```bash
# 1. What CPU is this actually?
lscpu | grep -E 'Model name|CPU family|Model:'
cat /sys/devices/system/cpu/cpu0/topology/package_cpus_list   # sibling layout

# 2. What's the kernel paranoid level?
cat /proc/sys/kernel/perf_event_paranoid
# Common default: 2. IBS needs <= 1 (non-root). System-wide uProf needs <= 0.

# 3. What profiling binaries are available?
command -v AMDuProfCLI AMDuProfPcm perf samply hotspot likwid-perfctr bpftrace

# 4. If uProf is absent, install from https://www.amd.com/en/developer/uprof.html
#    (EULA-gated download; no stable URL).

# 5. Is the NMI watchdog eating a PMC?
cat /proc/sys/kernel/nmi_watchdog
# If 1, AMD-recommended disable: sudo sysctl -w kernel.nmi_watchdog=0

# 6. What CPU governor?
cpupower frequency-info -p
# For reproducible profiling, pin to performance: sudo cpupower frequency-set -g performance

# 7. If uProf is installed, confirm it runs with a canary
AMDuProfCLI --version
AMDuProfCLI info --system
AMDuProfCLI info --list collect-configs
```

If the canary `AMDuProfCLI collect --config tbp -o /tmp/canary /bin/ls` returns error `0x80004005` (driver failed to start profiling), the proprietary Power Profiler Driver has an issue. Workaround: add `--use-linux-perf` to every `collect` invocation in this session — routes through the in-tree kernel perf subsystem and sidesteps the DKMS module entirely.

## Decision: which tool, when?

This is the central decision the skill must get right. The answer is almost never "uProf alone" — it's a tool *combination*.

| Goal | First reach | Why | See |
|---|---|---|---|
| "Where is my CPU time going?" (hotspots, native code) | `perf record -F 997 --call-graph dwarf` + `samply` or `hotspot` | Lowest friction, perf.data converts to everything. uProf adds little for pure hotspot hunt. | [perf-complements.md](references/perf-complements.md) |
| "Classify the bottleneck: frontend/backend/mispred/retiring" (Zen 4+) | `AMDuProfCLI collect --config assess -g ./app` | uProf's `assess` is pre-curated TMA. On Zen 2/3, fall back to perf with manual formulas. | [tma-on-amd.md](references/tma-on-amd.md) |
| "Which instructions / source lines cause cache misses?" | `AMDuProfCLI collect --config ibs` OR `perf record -e ibs_op/cnt_ctl=1/ -c 250000` | IBS Op with L3MissOnly filter (Zen 4+) is the precise answer. | [ibs-mechanics.md](references/ibs-mechanics.md) |
| "Am I memory-bandwidth-bound?" (whole-system) | `AMDuProfPcm -m memory -a -d 60 -o mem.csv` | PCM gives read/write GB/s across UMCs. Compare to DDR5 peak. | [uprof-recipes.md](references/uprof-recipes.md) |
| "Build a roofline chart" (Zen 4+) | `AMDuProfPcm roofline -o roofline.csv -- ./app && AMDuProfModelling.py ...` | No `perf` equivalent with equivalent UX. | [uprof-recipes.md](references/uprof-recipes.md) |
| "Per-core frequency/power/thermal timeline" | `AMDuProfCLI timechart --event core=0-N,power --interval 10 -d 30 -o out` | Power timechart is a uProf differentiator. Requires the Power Profiler Driver. | [uprof-recipes.md](references/uprof-recipes.md) |
| "False sharing?" (two atomics on one cache line) | `perf c2c record -g -- ./app && perf c2c report` | No uProf equivalent. | [perf-complements.md](references/perf-complements.md) |
| "Off-CPU / blocked time" (mutex, I/O, sched wait) | `bpftrace` or `offcputime-bpfcc` or `perf sched record` | uProf is sampling-on-CPU only. | [perf-complements.md](references/perf-complements.md) |
| "Per-container / per-cgroup profile" (Kubernetes pod) | `perf record --cgroup=/sys/fs/cgroup/...` | uProf has no cgroup scope. | [perf-complements.md](references/perf-complements.md) |
| "HPC region-scoped counters with MPI" | `likwid-perfctr -C E:N:M -g CACHE -m -- mpirun ./app` | LIKWID's region API + MPI harness. | [perf-complements.md](references/perf-complements.md) |
| "Compare two runs" (before/after optimization) | `AMDuProfCLI compare --baseline ./a --with ./b` OR `perf diff a.data b.data` | uProf's `compare` is turnkey for uProf sessions; `perf diff` for perf.data. | [uprof-recipes.md](references/uprof-recipes.md) |
| "Share profile with teammates on different hardware" | `perf record` + upload to [profiler.firefox.com](https://profiler.firefox.com) via samply, OR flame graph SVG | uProf's `.caperf` is lock-in; teammates need uProf too. | [perf-complements.md](references/perf-complements.md) |

**Default posture:** start with `perf record -F 997 --call-graph dwarf -- ./app` and `samply record -- ./app`. Add uProf when you need (a) IBS Op with AMD's pre-curated reports, (b) roofline, (c) power timechart, or (d) AMD-flavored TMA on Zen 4+.

## Phase-structured workflow

### Phase 1: Understand the question

Before profiling anything, name the bottleneck category you're looking for:

- **Compute-bound**: high IPC, high retiring fraction, near-peak SIMD throughput.
- **Memory-bound**: high cache-miss or DRAM-traffic fraction, low IPC even at high utilization.
- **Frontend-bound**: high `frontend_bound_latency` (iTLB/icache/BPU misses) or `frontend_bound_bandwidth` (decoder can't keep up).
- **Bad speculation**: high branch misprediction rate, wasted work.
- **Blocked / off-CPU**: threads spend time in kernel wait, locks, I/O — sampling on-CPU profilers give zero signal.
- **Scaling-limited**: single-thread fine, multi-thread stalls — look for false sharing, lock contention, cross-CCD traffic.

The category determines the tool. "Profile the app" without a hypothesis wastes time. If the user hasn't named a hypothesis, ask or run a cheap overview first (`perf stat -d -d -d -- ./app` + `AMDuProfCLI collect --config assess` on Zen 4+).

### Phase 2: Build prerequisites

1. **Compile for profiling.** C/C++: `-g -O2 -fno-omit-frame-pointer`. Rust: `[profile.release] debug = true` + `RUSTFLAGS="-C force-frame-pointers=yes -C symbol-mangling-version=v0"`. Go: use release build with default inlining (`-N -l` destroys optimization and produces worthless profiles — don't use it here).
2. **Disable NMI watchdog** (returns 1 PMC to user space).
3. **Pin governor to `performance`** (or at least confirm it's not `powersave`).
4. **Pin workload affinity** via `taskset` or uProf `--affinity` to avoid scheduler noise across CCDs.
5. **Verify `perf_event_paranoid`** matches the scope you need (see [install-troubleshoot.md](references/install-troubleshoot.md)).
6. **Warm-up.** First iteration is cold cache. Run 3-5 iterations or use hyperfine's `--warmup`. Don't measure the first run.

### Phase 3: Collect

Pick one of the recipes from [uprof-recipes.md](references/uprof-recipes.md) or [perf-complements.md](references/perf-complements.md) based on Phase 1 hypothesis. Key recipes to memorize:

```bash
# Hotspot hunt (fastest path)
perf record -F 997 --call-graph dwarf -g -- ./app
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# OR via samply
samply record -- ./app   # opens profiler.firefox.com

# uProf TMA assess (Zen 4+ microarch overview)
AMDuProfCLI collect --config assess -g --use-linux-perf -o ./uprof_assess ./app
AMDuProfCLI report -i ./uprof_assess/*.ses -f csv -o ./assess.csv

# uProf IBS Op with callstack (the Zen attribution tool)
AMDuProfCLI collect --config ibs -g --use-linux-perf -o ./uprof_ibs ./app

# OR via perf
perf record -e ibs_op/cnt_ctl=1/ -c 250000 --call-graph dwarf -g -- ./app

# Memory bandwidth (system-wide, requires perf_event_paranoid <= 0)
sudo AMDuProfPcm -m memory -a -d 60 -o /tmp/pcm_mem.csv

# Timechart: per-core freq + power, 10 ms interval, 30 s
AMDuProfCLI timechart --event core=0-15,power --interval 10 -d 30 -o ./tc
```

### Phase 4: Interpret

Profile interpretation is where most beginners stall. The interpretation guide is Zen-generation-aware:

- **TMA numbers.** Use the Zen 4+ formulas in [tma-on-amd.md](references/tma-on-amd.md). The single biggest mistake is using Zen 4's `total_dispatch_slots = 6 * cycles` on Zen 5 (dispatch is 8-wide). Always read the generation's `pipeline.json` from the kernel tree or uProf's `assess` output.
- **IBS Op samples.** IP is precise, count is approximate. Quote samples as "X% of observed retired ops came from this line", not "X% of all execution." See [ibs-mechanics.md](references/ibs-mechanics.md) for the full contract.
- **DataSrc attribution.** Zen 4+ DataSrc fields distinguish local DRAM, remote-CCD cache, remote-socket cache. On Zen 2/3 the field is coarser. [zen-generation-matrix.md](references/zen-generation-matrix.md) has the table.
- **Memory bandwidth.** `AMDuProfPcm -m memory` gives aggregate across all UMCs on the socket. Compare to theoretical peak (DDR5-4800 × 12 channels × 8 B ≈ 460 GB/s per EPYC socket). Utilization >60-70% indicates memory-bound.
- **Power.** RAPL updates every 1 ms; sampling faster than 1 ms just oversamples the same value. AMD has no DRAM RAPL domain (unlike Intel).

### Phase 5: Verify + iterate

Performance claims need independent corroboration:

- Cross-check uProf IBS results against `perf record -e ibs_op//` on the same workload. Results should agree within 10% (remember IBS's count imprecision).
- Cross-check memory bandwidth with `perf stat -e power/energy-pkg/ -e amd_df/...` or `pcm-memory`.
- When optimizing, use `hyperfine` for wall-clock comparison (honest end-to-end measure). Counter improvements that don't reduce wall-clock are artifacts.
- Profile on the same CPU generation as production. Zen 3 → Zen 4 differences (dispatch slot attribution, UMC counters) are large enough to invalidate conclusions.

## When the skill should stop and escalate

Stop and surface the problem to the user when:

1. **uProf canary collection fails and `--use-linux-perf` also fails.** The environment is broken; investigate kernel/distro/permissions before burning time on recipes.
2. **The workload requires a scope uProf doesn't support** (cgroup, pid-namespace, off-CPU). Route to `perf` or `bpftrace` without pretending uProf can.
3. **The user asks for a metric that's generation-unsupported** (e.g., `LdLat` on Zen 4, TMA on Zen 2). Name the limitation and offer the closest available substitute.
4. **Results disagree by >2× between tools.** This is not "tool disagreement" — it's a bug somewhere. Stop and diagnose before publishing numbers.

## References (load as needed)

- [references/uprof-recipes.md](references/uprof-recipes.md) — comprehensive AMDuProfCLI / AMDuProfPcm / AMDuProfSys / timechart CLI recipes with flags
- [references/ibs-mechanics.md](references/ibs-mechanics.md) — Instruction-Based Sampling: hardware contract, precision, per-gen capabilities, interpretation rules
- [references/zen-generation-matrix.md](references/zen-generation-matrix.md) — Zen 2/3/4/5 differences that affect profiling (dispatch width, UMC, CCX, DF, IBS filters)
- [references/tma-on-amd.md](references/tma-on-amd.md) — Top-Down Microarchitecture Analysis on Zen 4+: formulas, Level-1/Level-2 buckets, interpretation, counter budget
- [references/install-troubleshoot.md](references/install-troubleshoot.md) — install paths per distro, `perf_event_paranoid` matrix, known uProf 5.x bugs with workarounds, Secure Boot, cloud-EPYC caveats
- [references/perf-complements.md](references/perf-complements.md) — Linux `perf` with AMD events, samply, hotspot, likwid, bpftrace, AMD's own perf IBS metric scripts

## Related skills / files

- `vs-core-_shared/prompts/language-specific/perf-judgment.md` — general performance-engineering judgment (TMA concept, false sharing, TLB ceiling, algorithmic choices, etc.). This skill is the *tool* companion to that *judgment*.
- `vs-core-debug` — when performance problem is a reproducible bug; use debug's reproduce/hypothesize/discriminate flow, invoke this skill for the profiling steps.
- `vs-core-research` — when you need deep technical research beyond what these references cover (e.g., a specific hardware erratum or a new kernel feature).
- `vs-core-implement` — when the profiling feeds into a multi-file optimization implementation.

## Trigger phrases (routing hints)

"profile this on AMD", "run uProf", "use AMDuProfCLI", "collect IBS samples", "instruction-based sampling", "Zen 4 TMA", "Zen 5 TMA", "is this memory-bound on EPYC", "per-CCD L3 miss", "AMD top-down", "roofline on Zen", "power timechart", "AMDuProfPcm memory bandwidth", "UMC counter", "amd-pstate governor for profiling", "cache profiling on Ryzen", "flame graph on EPYC", "profile native Rust on Zen 4", "CCX cross-die traffic", "NPS1 vs NPS4", "AMD Data Fabric events", "amd_uncore", "perf on Zen".
