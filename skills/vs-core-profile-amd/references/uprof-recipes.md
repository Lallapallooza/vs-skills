# AMD uProf CLI Recipe Library

Concrete, verified CLI invocations for AMD uProf 5.x on Linux. Each recipe names the goal, the command, and the follow-up to interpret the output. Flags correspond to `AMDuProfCLI --version 5.x` as documented at [docs.amd.com 57368 uProf User Guide](https://docs.amd.com/r/en-US/57368-uProf-user-guide/).

Binary names used below: `AMDuProfCLI`, `AMDuProfPcm`, `AMDuProfSys`, `AMDuProfCfg`. If the packaging on your distro wraps them (e.g., FHS env, containerized launcher), substitute the wrapper name — flag semantics are identical.

## Pre-flight

```bash
# Version & capabilities
AMDuProfCLI --version
AMDuProfCLI info --system              # CPU, OS, driver status
AMDuProfCLI info --list collect-configs  # predefined config names on THIS install
AMDuProfCLI info --list predefined-events
AMDuProfCLI info --list pmu-events      # raw AMD PMC events

# Canary: does collection actually work?
AMDuProfCLI collect --config tbp -o /tmp/canary /bin/ls
echo $?   # 0 = success
ls /tmp/canary/   # should contain session.ses plus data files
```

If the canary fails with `0x80004005`, try `--use-linux-perf`; if that works, the proprietary Power Profiler Driver is the issue.

## Top-level command structure

```
AMDuProfCLI <subcommand> [options] [-- <target> [args]]

Subcommands:
  collect     -- gather a profile session
  report      -- generate CSV/XLS from a session
  translate   -- convert raw data to SQLite for GUI import
  timechart   -- power/thermal/frequency/PMC timeline
  info        -- introspection (system, configs, events)
  compare     -- diff two sessions (alias: diff)

Companion binaries:
  AMDuProfPcm     -- per-core / system-wide counters (memory, L3, power, roofline)
  AMDuProfSys     -- system-wide profiler using kernel perf
  AMDuProfCfg     -- event/config file editor (GUI-oriented)
```

## Collect subcommand — flag catalog

| Flag | Meaning |
|---|---|
| `--config <name>` | Predefined: `tbp`, `assess`, `ibs`, `memory`, `data_access`, `inst_access`, `hotspots`, `threading` (verify list via `info --list collect-configs`). |
| `-e/--event <spec>` | Custom event: `event=<EventId>,user=1,os=0,interval=250000`. Repeat for multi-event. |
| `-o <dir>` | Output session directory (required). |
| `-g` | Collect callstacks. |
| `--call-graph <method>` | `dwarf` (best, needs `-g` compile), `fp` (frame pointer), `lbr` (Zen 4+ LBR V2). |
| `-a/--all-cpus` | System-wide. Requires `perf_event_paranoid <= 0` or root. |
| `-C/--cpu 0,5-10` | CPU list/ranges. |
| `-d/--duration <sec>` | Collection duration. Default: until target exits. |
| `-I/--interval <ms>` | TBP sampling interval. Default 1 ms. |
| `-D/--delay <ms>` | Delay before starting (lets target initialize). |
| `--affinity <CPUs>` | Pin target workload to specific CPUs. |
| `-p/--pid <pid>` | Attach to running process (Linux only). |
| `-t/--tid <tid>` | Attach to specific thread. |
| `--mux-interval <ms>` | PMC multiplexing interval. Min 16 ms. Default 100 ms. |
| `--use-linux-perf` | Route through kernel perf subsystem instead of AMD driver. **Strongly recommended in distros without the proprietary driver loaded, on cloud VMs, and under Secure Boot.** |
| `--wait-for-signal` | Pause until SIGUSR1 (external trigger). |
| `--trace mpi=openmpi,full` | MPI tracing mode. |
| `-V/--verbose` | Extra diagnostics (useful when debugging collection failures). |

## Recipes by goal

### Hotspots (time-based profiling)

```bash
# Basic hotspot profile with callstack
AMDuProfCLI collect --config tbp -g --use-linux-perf \
  -o ./uprof_hotspots ./myapp arg1 arg2

# Higher resolution (0.5 ms interval, 4x more samples)
AMDuProfCLI collect --config tbp -g --use-linux-perf \
  -I 0.5 -o ./uprof_hotspots_hires ./myapp

# Attach to running process for 30 s
AMDuProfCLI collect --config tbp -g --use-linux-perf \
  -p $(pidof myapp) -d 30 -o ./uprof_attach
```

Interpret with `AMDuProfCLI report -i ./uprof_hotspots/*.ses -f csv -o hotspots.csv` then sort by `SAMPLES` column.

### Microarch overview (TMA "assess" — Zen 4+)

```bash
# The AMD-curated top-down analysis
AMDuProfCLI collect --config assess -g --use-linux-perf \
  -o ./uprof_assess ./myapp

# Extended version (more L2 metrics, may multiplex)
AMDuProfCLI collect --config assess_ext -g --use-linux-perf \
  -o ./uprof_assess_ext ./myapp

# Report grouped by CCD for NUMA/chiplet analysis
AMDuProfCLI report -i ./uprof_assess/*.ses -G ccx -f csv -o by_ccd.csv
```

Look at the `Pipeline Utilization` breakdown: `Frontend_Bound`, `Backend_Bound`, `Bad_Speculation`, `Retiring`. See [tma-on-amd.md](tma-on-amd.md) for interpretation.

### IBS Op (precise instruction-level sampling)

```bash
# Full IBS Op profile with callstack
AMDuProfCLI collect --config ibs -g --use-linux-perf \
  -o ./uprof_ibs ./myapp

# Custom IBS Op with specific interval (dispatch-op mode)
AMDuProfCLI collect \
  -e event=IBS_OP,interval=250000,user=1,os=0 \
  -g --use-linux-perf -o ./uprof_ibs_custom ./myapp

# IBS Fetch (front-end analysis) -- Zen 3+ only; Zen 1/2 broken
AMDuProfCLI collect \
  -e event=IBS_FETCH,interval=250000,user=1,os=0 \
  -g --use-linux-perf -o ./uprof_ibsfetch ./myapp

# IBS Op with L3-miss-only filter (Zen 4+)
# Look for ibsop-l3miss in `info --list predefined-events` on a Zen 4+ box
AMDuProfCLI collect \
  -e event=IBS_OP_L3MISS,interval=50000 \
  -g --use-linux-perf -o ./uprof_l3miss ./myapp
```

**Critical:** never mix IBS with TBP/EBP events in a single custom config — uProf silently drops samples (documented bug in 5.x release notes).

For IBS interpretation, see [ibs-mechanics.md](ibs-mechanics.md).

### Memory / cache / TLB

```bash
# Cache false-sharing / data-access investigation
AMDuProfCLI collect --config memory -g --use-linux-perf \
  -o ./uprof_mem ./myapp

# dTLB + data-cache analysis
AMDuProfCLI collect --config data_access -g --use-linux-perf \
  -o ./uprof_dcache ./myapp

# L1i + iTLB analysis (front-end)
AMDuProfCLI collect --config inst_access -g --use-linux-perf \
  -o ./uprof_icache ./myapp
```

### Threading / concurrency

```bash
# Wait-object, lock, and threading analysis (Linux)
AMDuProfCLI collect --config threading -g --use-linux-perf \
  -o ./uprof_threading ./myapp
```

### System-wide (all cores, all processes)

```bash
# Requires perf_event_paranoid <= 0 (or sudo)
sudo AMDuProfCLI collect --config tbp -a -d 30 \
  -o ./uprof_sys

# Per-CPU range
sudo AMDuProfCLI collect --config tbp -C 0-7 -d 30 \
  -o ./uprof_ccd0

# OR using AMDuProfSys (designed for system-wide)
sudo AMDuProfSys collect -a -d 30 -o ./uprof_sys2
```

### Custom multi-event collection

```bash
# Count cycles + retired ops + L2 misses + iTLB misses simultaneously
# (stays within 4-event group — no multiplexing scaling)
AMDuProfCLI collect \
  -e event=cpu-cycles,interval=1000000 \
  -e event=ex_ret_ops,interval=1000000 \
  -e event=l2_cache_req_stat.core_requests_miss,interval=100000 \
  -e event=bp_l1_tlb_miss_l2_tlb_miss,interval=100000 \
  -g --use-linux-perf -o ./custom ./myapp
```

Event names come from `AMDuProfCLI info --list pmu-events` on your hardware (Zen-gen-specific).

## Report subcommand

```bash
# Generate CSV summary
AMDuProfCLI report -i ./session.ses -f csv -o report.csv

# XLS (Linux Perf mode only)
AMDuProfCLI report -i ./session.ses -f xls -o report.xls

# Time-series CSV (requires -I at collect time)
AMDuProfCLI report -i ./session.ses -T -f csv -o timeseries.csv

# Group by chiplet / socket / NUMA node
AMDuProfCLI report -i ./session.ses -G ccx -f csv -o by_ccd.csv
AMDuProfCLI report -i ./session.ses -G numa -f csv -o by_numa.csv
AMDuProfCLI report -i ./session.ses -G system -f csv -o by_system.csv

# Higher precision (default is 3 decimals)
AMDuProfCLI report -i ./session.ses --set-precision 6 -f csv -o precise.csv

# Export as zip for sharing (session has many files)
AMDuProfCLI report -i ./session.ses --export-session -o session.zip
```

**Output formats in 5.x CLI:** CSV and XLS only. No native JSON, HTML, XML, or pprof. GUI can export flame graphs and additional views.

## Translate subcommand

Converts raw data to SQLite for the GUI to ingest.

```bash
AMDuProfCLI translate -i ./session-dir
# produces ./session-dir/*.db that GUI can import
```

Also useful: if report on a raw session is slow, `translate` once and then `report` from the `.db` is faster.

## Timechart subcommand

Records a timeline of per-core frequency, power, thermal, and selected PMC events.

```bash
# Enumerate available timechart events on this host
AMDuProfCLI timechart --list

# Per-core frequency + package power, 10 ms interval, 30 s
AMDuProfCLI timechart --event core=0-15,power \
  --interval 10 -d 30 -o ./tc

# With an executable (collects during workload only)
AMDuProfCLI timechart --event core=0-7,power \
  --interval 10 --affinity 0-7 -o ./tc_app ./myapp

# Per-core thermal
AMDuProfCLI timechart --event core-temperature=0-15 \
  --interval 10 -d 30 -o ./tc_temp
```

**Requires the Power Profiler Driver** (proprietary, DKMS-built). On systems without the driver, timechart may still report PMC-sourced events but not the AMD-proprietary power/thermal stream. To install the driver (from a tarball install):
```bash
sudo <uProf-install-dir>/bin/AMDPowerProfilerDriver.sh install
```
RPM/DEB packages install the driver automatically via DKMS.

**Interval floor:** 1 ms, but RAPL updates at ~1 ms so requesting <1 ms just oversamples the same energy value.

## Compare / diff subcommand

```bash
AMDuProfCLI compare --baseline ./uprof_baseline --with ./uprof_optimized \
  -o ./diff_report

# Report with percentage delta
AMDuProfCLI compare --baseline ./a --with ./b --percentage -o ./diff
```

Requires both sessions to use the same profile configuration. Compares function-level samples; highlights regressions and improvements.

## AMDuProfPcm recipes

AMDuProfPcm is the system-wide counter utility. Modes via `-m <mode>`:

### Memory bandwidth

```bash
# Aggregate DRAM bandwidth (GB/s) across all UMCs for 60 s
sudo AMDuProfPcm -m memory -a -d 60 -o /tmp/pcm_mem.csv

# Live streaming to stdout (-r)
sudo AMDuProfPcm -r -m memory -a -o -
```

The output CSV has columns for read GB/s, write GB/s, total GB/s per socket and per UMC. Compare to theoretical peak:
- EPYC Genoa/Bergamo (DDR5-4800, 12 channels): ~460 GB/s per socket
- Ryzen 7000 desktop (DDR5-5200, 2 channels): ~83 GB/s

### Per-core counters

```bash
# Per-core counter snapshot
sudo AMDuProfPcm -m per_core -a -d 30 -o /tmp/pcm_percore.csv

# Bind to a workload (collect only during run)
sudo AMDuProfPcm -m per_core -o /tmp/pcm_percore_app.csv -- ./myapp
```

### L3 cache

```bash
# L3 accesses, misses, average miss latency (in cycles)
sudo AMDuProfPcm -m l3 -a -d 30 -o /tmp/pcm_l3.csv
```

Per-CCD breakdown (Zen 3+): 6 counters per CCD; L3 fill events, L3 hits, L3 misses.

### Power

```bash
# Core + package RAPL energy over 30 s
sudo AMDuProfPcm -m power -a -d 30 -o /tmp/pcm_power.csv
```

RAPL is socket-level (`MSR_PKG_ENERGY_STAT 0xc001029B`) and per-core (`MSR_CORE_ENERGY_STAT 0xc001029A`). AMD does NOT expose a DRAM RAPL domain (unlike Intel).

### Roofline

```bash
# Collect roofline data
sudo AMDuProfPcm roofline -o /tmp/roofline.csv -- ./myapp

# Build the chart (memory speed in MT/s -- DDR5-4800 = 4800)
AMDuProfModelling.py -i /tmp/roofline.csv \
  -o /tmp/roofline_plot/ \
  --memspeed 4800 -a myapp
```

The `AMDuProfModelling.py` script is bundled with uProf. Output is an HTML chart showing application arithmetic intensity (FLOPS/byte) vs. the hardware roofline (peak FLOPS and peak bandwidth). Points below the diagonal = memory-bound; points near the peak horizontal = compute-bound.

### Mode-selector cheat sheet

| `-m` value | Measures |
|---|---|
| `memory` | DRAM read/write bandwidth aggregated across UMCs |
| `per_core` | Per-core PMC counter snapshots |
| `l3` or `llc` | L3 cache hits/misses/latency |
| `power` | Core + package RAPL energy |

Exact spelling (`per_core` vs `per-core`, `l3` vs `llc`) drifts between versions — run `AMDuProfPcm --help` to confirm on your install.

## AMDuProfSys

System-wide companion to AMDuProfCLI, designed to use the kernel perf subsystem.

```bash
# 30-second system-wide profile
sudo AMDuProfSys collect -a -d 30 -o ./sys_session

# Specific cores
sudo AMDuProfSys collect -C 0,1,2,3 -I 100 -o ./core_session
```

Pairs with `AMDuProfSys report -i ./sys_session/*.ses -f csv -o sys.csv`.

## MPI profiling

```bash
# TBP with MPI trace
mpirun -n 4 AMDuProfCLI collect --config tbp -g --trace mpi=openmpi,full \
  -o ./mpi_rank%r ./mpi_app

# Per-rank output dirs (use %r or manually rotate)
for rank in 0 1 2 3; do
  AMDuProfCLI collect --config tbp -g --use-linux-perf \
    -o ./rank_$rank ./launch_rank.sh $rank &
done
wait
```

**Known MPI pitfalls (uProf 5.x):**
- IBS + MPI → "very large datasets accumulate" (release notes, 5.x). Use IBS sequentially per-rank if needed.
- MPI report volume is not evenly distributed across ranks — uProf's per-rank volume counts disagree with other MPI tracing tools. Cross-check with `mpi_profile` or `tau` if quantitative byte-count matters.

## Output artifact layout

After `collect`, the session directory contains:

```
./uprof_session/
├── <timestamp>_<app>.caperf    # raw Linux Perf-mode data (or .prd for MSR mode)
├── session.ses                 # session metadata
├── translated/
│   └── <db-files>.db           # SQLite, produced by `translate`
└── ...
```

**No `.caperf` / `.prd` → `perf.data` conversion tool exists.** If flamegraph / pprof / samply output is needed, collect separately with `perf record`.

## Common errors and workarounds

| Error | Cause | Workaround |
|---|---|---|
| `0x80004005` "driver failed to start profiling" | Proprietary Power Profiler Driver not loaded or broken | `--use-linux-perf`; or reinstall driver; or hex-patch sysconf bug (legacy 4.1.x) |
| `0x8000ffff` on single-event collection | fd limit hit | `ulimit -n 65535` before collect |
| "NMI watchdog is enabled..." | NMI eating PMC | `sudo sysctl -w kernel.nmi_watchdog=0` (requires root on HPC systems) |
| "perf_event_paranoid is too high" | Kernel default often 2 | `sudo sysctl -w kernel.perf_event_paranoid=1` (or 0 for -a) |
| `AMDuProfCLI` hangs translating raw | Large MPI session (>200 GB) | Reduce rank count or duration; use `--use-linux-perf` |
| Empty or near-empty IBS Fetch report | Zen 1 / Zen 2 hardware | Use IBS Op instead (Zen 1/2 Fetch is a known-broken limitation) |
| GUI crashes on AWS EPYC Genoa | Documented in 5.x release notes | Use CLI only; or switch to bare metal |
| Callstacks missing frames | Missing `-g` compile or omitted FP | Recompile with `-g -fno-omit-frame-pointer`; try `--call-graph dwarf` |
| Rust names mangled as `_ZN...` | Legacy symbol format | `RUSTFLAGS="-C symbol-mangling-version=v0"` |

More in [install-troubleshoot.md](install-troubleshoot.md).

## Quick-reference card

```bash
# I want to... | ...run this
Find hotspots                      | AMDuProfCLI collect --config tbp -g --use-linux-perf -o out ./app
Classify bottleneck (Zen 4+)       | AMDuProfCLI collect --config assess -g --use-linux-perf -o out ./app
Precise cache-miss attribution     | AMDuProfCLI collect --config ibs -g --use-linux-perf -o out ./app
Memory bandwidth                   | sudo AMDuProfPcm -m memory -a -d 60 -o mem.csv
Roofline chart                     | sudo AMDuProfPcm roofline -o rl.csv -- ./app; AMDuProfModelling.py -i rl.csv -o plot/ --memspeed 4800 -a app
Per-core freq/power timeline       | AMDuProfCLI timechart --event core=0-15,power --interval 10 -d 30 -o tc
Compare two runs                   | AMDuProfCLI compare --baseline a --with b -o diff
Report a session                   | AMDuProfCLI report -i session.ses -f csv -o report.csv
Attach to running PID              | AMDuProfCLI collect --config tbp -g -p $(pidof app) -d 30 -o out
System-wide (root)                 | sudo AMDuProfCLI collect --config tbp -a -d 30 -o out
```
