# `perf` + Ecosystem Complements for AMD Profiling

uProf is not the only AMD profiling tool — and often not the right first tool. Linux `perf` with AMD-specific events, plus `samply` / `hotspot` / `likwid` / `bpftrace`, covers cases uProf doesn't (cgroups, off-CPU, cross-vendor, sharing profiles). This reference is the operational companion to [uprof-recipes.md](uprof-recipes.md).

## `perf` on AMD Zen — what's available

All of uProf's data comes from the same kernel interfaces (`perf_event_open`) that `perf` uses. What uProf adds is AMD-curated configs, a GUI, and AMD-authored TMA metrics. What `perf` adds is: container scoping, ecosystem integrations, portability, no DKMS dependencies.

AMD-specific events exposed by `perf`:

```bash
# List AMD PMUs
perf list pmu | grep -i amd
# Typical output:
#   amd_df                       # Data Fabric (socket-level)
#   amd_l3_ccd0 / amd_l3_ccd1 ...# Per-CCD L3 PMU (Zen 3+) or per-CCX (Zen 2)
#   amd_umc_0 / amd_umc_1 ...    # Memory controller (Zen 4+)
#   ibs_op / ibs_fetch           # Instruction-Based Sampling
#   power                        # RAPL energy counters

# All events
perf list | grep -iE 'ibs|amd_df|amd_l3|amd_umc|power/energy'

# AMD-specific raw events (Zen-gen-specific; curated JSON in kernel)
perf list core               # CPU core PMC events
perf list cache              # cache subsystem
perf list tlb                # TLB events
perf list branch             # branch predictor
```

Events defined in `tools/perf/pmu-events/arch/x86/amdzen{1,2,3,4,5}/` in the kernel tree. On a running system the same JSON is embedded in the `perf` binary.

## Hotspot hunt — the default path

```bash
# Compile with debug + frame pointers
gcc -O2 -g -fno-omit-frame-pointer myapp.c -o myapp

# Record 997 Hz (prime; avoids aliasing with 1000 Hz system timers)
perf record -F 997 --call-graph dwarf -g -- ./myapp

# View top
perf report --stdio --no-children | head -40

# Flame graph
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# Firefox Profiler / samply
perf script report | ...  # or use samply directly
```

Alternatively, skip perf and use samply directly:

```bash
# samply is a frontend to perf_event_open that opens profiler.firefox.com
samply record -- ./myapp
# A browser tab opens with the profile loaded
```

## IBS via `perf`

```bash
# IBS Op with 250k-op period (dispatch-op mode)
perf record -e ibs_op/cnt_ctl=1/ -c 250000 --call-graph dwarf -g -- ./myapp

# IBS Fetch
perf record -e ibs_fetch// -c 250000 --call-graph dwarf -g -- ./myapp

# L3 miss only (Zen 4+)
perf record -e ibs_op/l3missonly=1,cnt_ctl=1/ -c 100000 -- ./myapp

# Load-latency filter (Zen 5+; N = cycles threshold, 128-2048)
perf record -e ibs_op/ldlat=512,cnt_ctl=1/ -c 50000 -- ./myapp

# Inspect samples with raw IBS data
perf script -F ip,sym,dso,period,brstack,ibs_op.data2 -i perf.data
```

AMD's own perf scripts for IBS metrics (when present in your perf tree):

```bash
perf script report amd-ibs-op-metrics
perf script report amd-ibs-op-metrics-annotate
perf script report amd-ibs-fetch-metrics
```

These compute IPC, cache-miss ratios, and source attribution from IBS raw samples in a style uProf pre-builds. Source: [patchew.org Ravi Bangoria RFC Jan 2025](https://patchew.org/linux/20250124060638.905-1-ravi.bangoria@amd.com/). If your kernel / perf is older, the scripts may not be present — check `ls /usr/libexec/perf/scripts/python/`.

## Data Fabric + UMC memory counters

### Aggregate DRAM bandwidth (Zen 4+)

```bash
# All UMC channels, for a 30 s workload
perf stat -a \
  -e amd_umc_0/umc_cas_cmd.all/ \
  -e amd_umc_1/umc_cas_cmd.all/ \
  -e amd_umc_2/umc_cas_cmd.all/ \
  -e amd_umc_3/umc_cas_cmd.all/ \
  ... \
  -- ./myapp

# Read vs write breakdown
perf stat -a -e amd_umc_0/umc_cas_cmd.rd/,amd_umc_0/umc_cas_cmd.wr/ -- ./myapp
```

Multiply the `umc_cas_cmd.all` count by 64 bytes (cache line) to get total bytes, divide by duration for GB/s.

### Data Fabric cross-CCD traffic (all Zen)

```bash
# Example DF event (check `perf list amd_df` for your generation)
perf stat -a -e amd_df/event=0x47,umask=0x03/ -- ./myapp
```

See LIKWID wikis and AMD PPR for per-generation event codes.

## `perf c2c` for false sharing

[`perf c2c`](https://www.man7.org/linux/man-pages/man1/perf-c2c.1.html) (cache-to-cache) is the only practical tool for detecting false-sharing-induced cross-core cache-line bouncing. Works on AMD.

```bash
sudo perf c2c record --call-graph dwarf -- ./myapp
sudo perf c2c report --stdio | head -80
```

Interpret: the "HITM" (hit modified) column shows cache lines being fought over across cores. High HITM with low ops/line = false sharing. Pad structs (64 B alignment), separate reader/writer fields onto different cache lines.

No uProf equivalent exists.

## Off-CPU profiling

Sampling profilers like uProf and `perf record` measure *on-CPU* time only. For latency-bound workloads (I/O, mutex contention, scheduler waits), you need off-CPU or wake-up analysis. None of this is in uProf.

### bpftrace one-liner

```bash
# Off-CPU time by stack trace
sudo bpftrace -e '
kprobe:finish_task_switch {
  @[kstack, comm] = sum(nsecs - @start[tid]);
}
kprobe:finish_task_switch {
  @start[tid] = nsecs;
}
interval:s:10 { print(@); clear(@); exit(); }'
```

### bcc-tools

```bash
# Install bcc-tools via distro package (apt install bpfcc-tools, dnf install bcc-tools, etc.)
sudo offcputime-bpfcc -df 30 > offcpu.stacks
./stackcollapse.pl offcpu.stacks | ./flamegraph.pl --color=io \
  --title="Off-CPU Time Flame Graph" > offcpu.svg
```

### `perf sched`

```bash
sudo perf sched record -- ./myapp
sudo perf sched latency | head -40
sudo perf sched timehist | head -80
```

### async-profiler / wall-clock flame graphs

For JVM workloads (if applicable), `async-profiler --event=wall` gives wall-clock flame graphs. For Python, `py-spy --idle` shows off-CPU.

## Per-cgroup / per-container profiling

```bash
# List cgroups
ls /sys/fs/cgroup/

# Profile a specific cgroup (e.g., Kubernetes pod by its cgroup path)
perf record -F 997 --call-graph dwarf -g \
  --cgroup=/sys/fs/cgroup/system.slice/my-service.scope -- sleep 30

# Multiple cgroups
perf stat -e cycles,instructions \
  --cgroup /sys/fs/cgroup/A --cgroup /sys/fs/cgroup/B \
  -- sleep 10
```

uProf has no cgroup scope — this is a `perf`-only capability.

## LIKWID — HPC regions and event groups

LIKWID is the best option for scripted / HPC-style region measurement on Zen. Designed for: event groups, source-marked regions, MPI harness, reproducible across runs.

```bash
# Topology
likwid-topology

# Measure TMA Level-1 on cores 0-15
likwid-perfctr -C 0-15 -g TMA_L1 -m -- ./myapp

# Per-region measurement via source markers (C/C++/Fortran)
# #include <likwid-marker.h>
# LIKWID_MARKER_INIT;
# LIKWID_MARKER_START("compute");
# ... code ...
# LIKWID_MARKER_STOP("compute");
# LIKWID_MARKER_CLOSE;
likwid-perfctr -C 0-15 -g CACHE -m ./myapp_marked

# MPI harness
likwid-mpirun -np 64 -nperdomain M:2 -g MEM ./mpi_app
```

Advantages over uProf:
- Curated event groups (`CACHE`, `MEM`, `FLOPS_DP`, `TMA_L1`, `L2`, `L3`, `BRANCH`, etc.).
- Source-level region markers — measure inside a function.
- Scriptable / reproducible — no GUI state.
- MPI-aware.
- No DKMS / Qt dependencies.

Per-Zen-gen group files: [github.com/RRZE-HPC/likwid/wiki/Zen4](https://github.com/RRZE-HPC/likwid/wiki/Zen4), [Zen3](https://github.com/RRZE-HPC/likwid/wiki/Zen3).

## hotspot (KDAB GUI)

Loads `perf.data` and shows flame graphs, top-down view, tracepoints, off-CPU.

```bash
# After perf record
perf record -F 997 --call-graph dwarf -- ./myapp
hotspot perf.data   # GUI opens
```

Features:
- Flame graph (top-down, bottom-up, left-heavy).
- Top-down / caller-callee tables.
- Off-CPU / wait / sleep analysis.
- Tracepoints.
- Works offline on any `perf.data`.

Pairs well with `perf record` on AMD; no AMD-specific features beyond what perf gives.

## samply

Cross-platform (Mac/Linux/Windows), wraps perf_event_open, uploads to [profiler.firefox.com](https://profiler.firefox.com) — the profile is URL-sharable.

```bash
# Record + open browser
samply record -- ./myapp

# Load existing perf.data
samply load perf.data
```

Strengths:
- Zero config.
- Profile is shareable via URL.
- Works on Macs too (useful for cross-platform teams).
- Understands inlined functions via DWARF.

Limitations:
- No AMD-specific metrics (just sampling).
- Read-only (no events, no counters) — just CPU time.

## AMD amd-perf-tools

AMD-authored helpers on the perf side of the fence: [github.com/AMDESE/amd-perf-tools](https://github.com/AMDESE/amd-perf-tools). Not profilers — verification/debug utilities.

- `pr-ibs` — decode IBS MSRs from raw samples; useful for verifying `perf record -e ibs_op//` is capturing what you expect.
- PMU dump scripts — confirm Core/L3/DF/IBS PMU programming on Zen.

Install via clone + build.

## hyperfine

Wall-clock benchmarking with JSON export. The "reality check" for any profile-guided optimization.

```bash
# Benchmark baseline vs optimized
hyperfine --warmup 3 './app_before' './app_after'

# Parameter sweep
hyperfine --warmup 3 './app --threads {t}' -P t 1 16

# JSON export for scripting
hyperfine --export-json bench.json --warmup 3 './app'
```

Rule: any optimization that shows as faster in TMA/IBS/perf but doesn't reduce `hyperfine` median time is suspect. Counters lie; wall clock doesn't.

## Flame graph variants

```bash
# Standard on-CPU flame graph
perf record -F 997 --call-graph dwarf -- ./app
perf script | stackcollapse-perf.pl | flamegraph.pl > cpu.svg

# Off-CPU flame graph (needs bcc/bpftrace)
sudo offcputime-bpfcc -df 30 > off.stacks
./flamegraph.pl --color=io --title="Off-CPU" < off.stacks > off.svg

# Differential flame graph (before vs after)
./difffolded.pl baseline.folded optimized.folded | ./flamegraph.pl > diff.svg

# Icicle graph (top-down)
./flamegraph.pl --reverse < stacks > icicle.svg
```

`flamegraph.pl` and `stackcollapse-perf.pl` come from Brendan Gregg's [FlameGraph repo](https://github.com/brendangregg/FlameGraph).

## Sharing profiles with teammates

The most common request uProf cannot satisfy: "send your profile to me so I can dig in."

- **samply** — URL-based, any teammate on any OS opens it in their browser.
- **Firefox Profiler + perf.data** — upload perf.data, [profiler.firefox.com](https://profiler.firefox.com) loads it.
- **Flame graph SVG** — read-only, small file, works in any browser.
- **pprof** — language-agnostic profile format; `perf` can emit `perf.data` → pprof via `pprof` tool.

```bash
# Convert perf.data to pprof
pprof -proto perf.data > profile.pb.gz

# View
pprof -http=:8080 profile.pb.gz
```

uProf's `.caperf` / `.prd` formats do not convert.

## perf `diff` / compare

```bash
# Record two runs
perf record -o before.data -F 997 --call-graph dwarf -- ./app
# ... optimize ...
perf record -o after.data -F 997 --call-graph dwarf -- ./app

# Diff
perf diff before.data after.data | head -30
```

Shows per-function sample delta and percentage change.

## Quick-reference: task → tool

| Task | Tool | Command |
|---|---|---|
| Pure hotspot hunt on native | perf + samply/hotspot | `samply record -- ./app` |
| AMD-specific IBS attribution | perf with IBS | `perf record -e ibs_op/cnt_ctl=1/ -c 250000 -- ./app` |
| AMD TMA (Zen 4+) | uProf OR perf pipeline.json | `perf stat --topdown -M TopdownL1 -- ./app` |
| Memory bandwidth on Zen 4+ | perf UMC events OR AMDuProfPcm | `perf stat -a -e amd_umc_0/umc_cas_cmd.all/ -- ./app` |
| False sharing | perf c2c | `sudo perf c2c record -- ./app; perf c2c report` |
| Off-CPU time | bpftrace / bcc | `sudo offcputime-bpfcc -df 30` |
| Lock contention | perf lock, bpftrace | `sudo perf lock record -- ./app; perf lock report` |
| Scheduler timeline | perf sched | `sudo perf sched record -- ./app; perf sched timehist` |
| Cgroup / container | perf --cgroup | `perf record --cgroup=/sys/fs/cgroup/X -- sleep 30` |
| HPC region-scoped | likwid-perfctr | `likwid-perfctr -C 0-15 -g TMA_L1 -m -- ./app` |
| Wall-clock A/B | hyperfine | `hyperfine './a' './b'` |
| Heap allocations | heaptrack (C++/Rust) | `heaptrack ./app; heaptrack_gui heaptrack.*.gz` |
| Python + native | scalene / py-spy | `scalene ./app.py` |
| Function-graph trace | uftrace | `uftrace record ./app; uftrace replay` |
| Dynamic trace, arbitrary | bpftrace | `sudo bpftrace -e '...'` |

## The honest truth

For the common case (profile a C/C++/Rust/Go binary on a Linux workstation with an AMD CPU), the first tool to reach for is:

```bash
samply record -- ./myapp    # or perf record + hotspot
```

Not uProf. uProf enters when you specifically need:
- Zen 4+ AMD-curated TMA (`assess` config).
- IBS Op with L3MissOnly or LdLat filters on Zen 4+/5+.
- AMDuProfPcm roofline (there's no equivalent).
- Power timechart (driver-dependent).
- AMD's opinion on which events to measure for a given microarch question.

For everything else, `perf` + `samply` + `hotspot` + `likwid` + `bpftrace` is a better default — lower install friction, broader community, and portable across AMD/Intel.

## References

- [perf Wiki — perf.wiki.kernel.org](https://perf.wiki.kernel.org/index.php/Main_Page)
- [perf-c2c(1) man page](https://www.man7.org/linux/man-pages/man1/perf-c2c.1.html)
- [perf-amd-ibs(1) man page](https://man7.org/linux/man-pages/man1/perf-amd-ibs.1.html)
- [Brendan Gregg — Flame Graphs](https://www.brendangregg.com/flamegraphs.html)
- [Brendan Gregg — Off-CPU analysis](https://www.brendangregg.com/offcpuanalysis.html)
- [samply — github.com/mstange/samply](https://github.com/mstange/samply)
- [hotspot — github.com/KDAB/hotspot](https://github.com/KDAB/hotspot)
- [LIKWID — github.com/RRZE-HPC/likwid](https://github.com/RRZE-HPC/likwid)
- [bcc / bpftrace — iovisor/bcc](https://github.com/iovisor/bcc)
- [FlameGraph scripts — brendangregg/FlameGraph](https://github.com/brendangregg/FlameGraph)
- [AMD amd-perf-tools — github.com/AMDESE/amd-perf-tools](https://github.com/AMDESE/amd-perf-tools)
- [AMD Ravi Bangoria perf IBS RFC](https://patchew.org/linux/20250124060638.905-1-ravi.bangoria@amd.com/)
- [Denis Bakhvalov — easyperf.net](https://easyperf.net/)
- [hyperfine — github.com/sharkdp/hyperfine](https://github.com/sharkdp/hyperfine)
- [pprof — github.com/google/pprof](https://github.com/google/pprof)
