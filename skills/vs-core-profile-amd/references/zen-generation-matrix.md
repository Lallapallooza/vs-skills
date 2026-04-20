# Zen Generation Matrix for Profiling

Profiling results on AMD Zen are generation-sensitive: counter layout, IBS capabilities, cache topology, and even dispatch width all change across generations. Recipes that ignore the generation give silently wrong results. This reference is the authoritative "what changed?" table.

## Family / Model / Kernel support

| Gen | Family | Notable models | `uname -p`-hint | Kernel support floor | Notes |
|---|---|---|---|---|---|
| Zen 1 | `17h` | Models 01h, 08h (Summit Ridge, Naples) | Ryzen 1000, EPYC 7001 | any modern | PMCs only (no IBS Op on some steps) |
| Zen 2 | `17h` | 31h (Rome), 71h (Matisse) | Ryzen 3000, EPYC 7002 | 4.19+ | IBS Op ✓; IBS Fetch "extremely low" samples |
| Zen 3 | `19h` | 01h (Milan), 21h (Vermeer) | Ryzen 5000, EPYC 7003 | 5.10+ | BRS (branch sampling, Zen 3 specific) |
| Zen 4 | `19h` | 10h–1Fh (Genoa, Raphael), 60h–6Fh (Phoenix, Bergamo) | Ryzen 7000, EPYC 9004 | 6.2+ (pipeline.json), 6.7+ (UMC) | PerfMonV2, LbrExtV2, UMC PMU, L3MissOnly |
| Zen 5 | `1Ah` | 00h–0Fh (Turin, Granite Ridge) | Ryzen 9000, EPYC 9005 | 6.10+ (core events), 6.13+ (DF extras) | Dispatch width 8, LdLat filter |
| Zen 6 | `1Ah` (likely) | preview | — | preview patches posted | Remote-socket DataSrc, fetch-latency filter |

Detect generation on the live machine:
```bash
# Model decode
cat /proc/cpuinfo | grep -E 'vendor_id|cpu family|model\s*:|model name' | head -8

# Perf PMU availability (shows amd_umc_* on Zen 4+, amd_df on all Zen)
perf list pmu | grep -i amd
ls /sys/bus/event_source/devices/ | grep amd

# IBS capabilities — look for /sys/bus/event_source/devices/ibs_op/format/
ls /sys/bus/event_source/devices/ibs_op/format/  # Zen 4+ shows l3missonly, Zen 5+ shows ldlat
```

## Hardware PMC layout

| Gen | Core GP PMCs | Core fixed PMCs | Counter width | L3 PMCs | L3 scope | DF (NB) PMCs | DF scope | UMC PMCs |
|---|---|---|---|---|---|---|---|---|
| Zen 1 | 4 (legacy) | 0 | 48-bit | 6 per CCX (2 CCX per CCD) | per-CCX | 4 | per-socket | — |
| Zen 2 | 6 (PerfCtrCore) | 3 | 48-bit | 6 per CCX (2 CCX per CCD) | per-CCX | 4 | per-socket | — |
| Zen 3 | 6 | 3 | 48-bit | 6 per CCD (unified CCX) | per-CCD | 4 | per-socket | — |
| Zen 4 | 6 (PerfMonV2) | 3 | 48-bit | 6 per CCD | per-CCD | 4 (`event14v2` format) | per-socket | **64 cfg/ctr per UMC** |
| Zen 5 | 6 (PerfMonV2) | 3 | 48-bit | 6 per CCD | per-CCD | 4 (extended events) | per-socket | 64 cfg/ctr per UMC |

**Key consequences:**

- With only 6 GP PMCs, fitting TMA Level 2 (~12 events) requires multiplexing → scaling error on bursty workloads. Prefer Level-1-only groups or run the workload twice with disjoint event sets.
- NMI watchdog consumes 1 PMC. Disable it for profiling (`sysctl -w kernel.nmi_watchdog=0`) to get full 6.
- UMC counters are Zen 4+ only. On Zen 2/3, memory-bandwidth attribution must come from DF counters or from PMC events like `ls_dispatch.dc_access` summed across cores.

## Dispatch width (TMA formula input)

**Single biggest trap when porting configs across generations:**

| Gen | Dispatch width (slots/cycle) | TMA formula fragment |
|---|---|---|
| Zen 2 | 4 | n/a (no dispatch-slot PMC) |
| Zen 3 | 6 | `total_dispatch_slots = 6 * ls_not_halted_cyc` (manual; no official AMD TMA yet) |
| Zen 4 | 6 | `total_dispatch_slots = 6 * ls_not_halted_cyc` (official AMD TMA) |
| **Zen 5** | **8** | **`total_dispatch_slots = 8 * ls_not_halted_cyc`** |

A hand-written Zen-4 TMA config run on Zen 5 will underestimate `total_dispatch_slots` by 25%, which *inflates* `retiring` (which is `ex_ret_ops / total_slots`) and *deflates* all bound percentages. This is a silent correctness bug.

**Authoritative formula source:** `tools/perf/pmu-events/arch/x86/amdzen{4,5}/pipeline.json` in the Linux kernel tree. uProf's `assess` config reads from the same event definitions. When in doubt, check the JSON on the target kernel.

Source: [Chips and Cheese — Discussing AMD's Zen 5 at Hot Chips 2024](https://chipsandcheese.com/p/discussing-amds-zen-5-at-hot-chips-2024), AMD PPR Family 1Ah doc 58550.

## CCX / CCD topology

CCX (Core Complex) = a group of cores sharing an L3. CCD (Core Complex Die) = a physical chiplet.

| Gen | CCX layout | L3 per CCX | L3 per CCD | Intra-CCD cross-CCX penalty | Cross-CCD traffic |
|---|---|---|---|---|---|
| Zen 1 | 4-core CCX, 2 CCX per "die" | 8 MiB | 16 MiB (as 2 × 8) | yes (via SDF) | via Infinity Fabric (same die) |
| Zen 2 | 4-core CCX, 2 CCX per CCD | 16 MiB | 32 MiB (as 2 × 16) | **yes** (via IOD!) | via IOD (slow) |
| Zen 3 | 8-core CCX, 1 CCX per CCD | 32 MiB | 32 MiB | n/a (unified) | via IOD |
| Zen 4 | 8-core CCX, 1 CCX per CCD | 32 MiB (64 on V-Cache) | 32 MiB | n/a | via IOD (faster GMI) |
| Zen 4 (Bergamo) | 16-core CCX per CCD (Zen 4c) | 16 MiB | 16 MiB | n/a | via IOD |
| Zen 5 | 8-core CCX per CCD | 32 MiB | 32 MiB | n/a | via IOD (GMI-Wide on server) |

**Zen 2 is special:** two 4-core CCXs per CCD, and cross-CCX-within-CCD traffic goes out to the IOD and back. Apparent "L3 miss to remote cache" on a 16-core Zen 2 Ryzen is often *on the same die* but crossing CCX. On Zen 3+ this is no longer possible (unified CCX per CCD).

**For profiling:**
- Zen 2: use IBS DataSrc to distinguish "intra-CCD cross-CCX" vs "cross-CCD" vs "remote-socket."
- Zen 3+: DataSrc distinguishes "local L3 / local CCD" vs "cross-CCD" vs "remote-socket."
- Group reports by CCX / CCD: `AMDuProfCLI report -G ccx ...` or `perf report --sort=... --per-socket`.

## Data Fabric (DF / NB) counters

Four per-socket counters accessible as `amd_df/event=...,umask=.../` via perf.

| Gen | DF event format | Key events |
|---|---|---|
| Zen 1-3 | `event` (14-bit concatenation) | CCM, IOM, CS, PCS event masks |
| Zen 4 | `event14v2` with extended umask semantics | + UMC-edge events (when combined with UMC PMU) |
| Zen 5 | Extended Zen 4 format | + read/write beats per DRAM channel, upstream DMA beats, cross-socket inbound/outbound beats |

**DF counters are per-socket, not per-thread.** You cannot attribute DF traffic to a specific thread by sampling DF events. The correct methodology is:

1. Sample IBS Op with a modest period (e.g., 500k) during the workload.
2. Filter IBS samples by `DataSrc == DRAM` → attribute to source instruction.
3. Independently, run `AMDuProfPcm -m memory` or `perf stat -e amd_umc_0/umc_cas_cmd.all/` (Zen 4+) for quantitative bandwidth.
4. Correlate in the same time window.

## NPS (NUMA Per Socket) modes on EPYC

EPYC server CPUs support multiple NUMA-topology modes:

| NPS mode | NUMA nodes per socket | Memory interleave | Cross-node latency |
|---|---|---|---|
| NPS1 | 1 | interleaved across all channels | highest worst-case (traffic may cross IOD twice) |
| NPS2 | 2 | interleaved within 2 quadrants | lower cross-node penalty |
| NPS4 | 4 | interleaved within 4 quadrants | lowest cross-node latency |

**Profile under the same NPS mode as production.** Switching from NPS1 to NPS4 changes apparent memory latency by 10-20% and can flip conclusions about whether an algorithm is memory-bound.

Detect:
```bash
numactl --hardware         # shows NUMA nodes and sizes
dmesg | grep -i 'numa node'
```

## Energy / power counters

| Gen | `MSR_RAPL_PWR_UNIT` | `MSR_CORE_ENERGY_STAT` | `MSR_PKG_ENERGY_STAT` | DRAM domain | Width |
|---|---|---|---|---|---|
| Zen 1-3 | `0xc0010299` | `0xc001029A` (per-core) | `0xc001029B` (per-socket) | **NOT exposed** | 32-bit (wraps) |
| Zen 4 (desktop) | `0xc0010299` | `0xc001029A` | `0xc001029B` | NOT exposed | 32-bit |
| Zen 4+ (server) | `0xc0010299` | `0xc001029A` | `0xc001029B` | NOT exposed | **64-bit** (no wrap) |

**Critical:** AMD has no DRAM RAPL domain on any Zen generation (unlike Intel Skylake-X and later). Memory energy cannot be directly measured via RAPL; you must estimate from `amd_umc_*` traffic counts × DDR energy per-byte (vendor-specific).

ESU (energy unit) is from `MSR_RAPL_PWR_UNIT[12:8]`; AMD default = 0xA → energy per LSB = 2^-10 J = ~0.977 µJ (wiki says 15.3 µJ — **this is a common misconception; actual ESU on most Zen is ~1 µJ, not 15.3**). Verify on the target:
```bash
sudo rdmsr 0xc0010299
# extract bits [12:8]; ESU = 2^-ESU Joules per LSB
```

Source: [Schöne et al. Cluster 2021 (arXiv 2108.00808)](https://arxiv.org/pdf/2108.00808), [amd_energy README](https://github.com/amd/amd_energy/blob/master/README.md).

## IBS capability progression

(Duplicates the table in [ibs-mechanics.md](ibs-mechanics.md) for quick reference.)

| Feature | Zen 2 | Zen 3 | Zen 4 | Zen 5 | Zen 6 |
|---|---|---|---|---|---|
| IBS Op | ✓ | ✓ | ✓ | ✓ | ✓ |
| IBS Fetch | ✗ (broken) | ✓ | ✓ | ✓ | ✓ |
| `L3MissOnly` | ✗ | ✗ | ✓ | ✓ | ✓ |
| `LdLat` threshold | ✗ | ✗ | ✗ | ✓ | ✓ |
| Extended DataSrc | partial | partial | ✓ | ✓ | + remote-socket |
| `IBS_BR_TARGET` | ✗ | ✓ | ✓ | ✓ | ✓ |

## Branch Sampling (BRS / LBR)

| Gen | Facility | Depth | Scope |
|---|---|---|---|
| Zen 1-2 | none | — | — |
| Zen 3 | BRS (AMD Branch Sampling) | 16 | cycles:pp equivalent (retired) |
| Zen 4+ | LbrExtV2 | 32 | precise branch chain with prediction info |

Use for: reconstructing call stacks without frame pointers (LBR-based stitching); confirming misprediction hot spots.

```bash
# Zen 3 BRS
perf record -b -e cycles:pp -- ./app

# Zen 4+ LBR V2
perf record --call-graph lbr -- ./app
```

## What changes when you change generations

Symptom-to-cause table:

| Symptom after generation change | Likely cause | Fix |
|---|---|---|
| Zen 5 TMA numbers look off (retiring = 100%+) | Hardcoded `6 * cycles` dispatch formula | Update to `8 * cycles` or use uProf's `assess` |
| `amd_umc_*` events not found | Pre-Zen 4 kernel or hardware | UMC PMU is Zen 4+ only; use DF counters instead |
| IBS Fetch samples ~0 | Zen 1/2 hardware | Switch to IBS Op for front-end questions |
| `L3MissOnly` filter fails | Pre-Zen 4 hardware | Remove filter; post-process IBS samples to filter by DataSrc |
| `LdLat` filter fails | Pre-Zen 5 hardware | Remove filter; rank by cache-miss latency in post-processing |
| DataSrc values look wrong for "remote" | Zen 2/3 coarser DataSrc encoding | Accept coarser attribution; move to Zen 4+ for fine-grained |
| RAPL numbers look wrong in long runs | 32-bit wrap on Zen 1-3 | Accumulate delta with wrap-handling; or use 64-bit on Zen 4+ server |
| Remote-socket DataSrc on Zen 5 | Remote-socket flag is Zen 6 preview | Zen 5 DataSrc treats all remote-CCX similarly; wait for Zen 6 or use DF |

## Quick generation probe

```bash
#!/usr/bin/env bash
# zen-gen.sh -- print Zen generation and key profiling capabilities

family=$(awk -F: '/cpu family/{gsub(/[^0-9]/,"",$2);print $2;exit}' /proc/cpuinfo)
model=$(awk -F: '/^model\s*:/{gsub(/[^0-9]/,"",$2);print $2;exit}' /proc/cpuinfo)
echo "Family: $family  Model: $model"

case "$family-$model" in
  17-1|17-8)   gen="Zen 1" ;;
  17-49|17-113) gen="Zen 2" ;;
  19-1|19-33)  gen="Zen 3" ;;
  19-1[67-9]|19-2[0-9]|19-9[6-9]|19-9[6-9]|19-104|19-96) gen="Zen 4" ;;
  26-*) gen="Zen 5" ;;
  *) gen="Unknown family/model: $family/$model" ;;
esac
echo "Generation: $gen"

# Check for Zen 4+ UMC PMU
[ -e /sys/bus/event_source/devices/amd_umc_0 ] && echo "UMC PMU: available (Zen 4+)" || echo "UMC PMU: NOT available (Zen 3-)"

# Check IBS L3MissOnly support
[ -e /sys/bus/event_source/devices/ibs_op/format/l3missonly ] && echo "IBS L3MissOnly: yes (Zen 4+)" || echo "IBS L3MissOnly: no"

# Check IBS LdLat support
[ -e /sys/bus/event_source/devices/ibs_op/format/ldlat ] && echo "IBS LdLat: yes (Zen 5+)" || echo "IBS LdLat: no"

# Check for PerfMonV2
grep -qi perfmon_v2 /proc/cpuinfo && echo "PerfMonV2: yes (Zen 4+)" || echo "PerfMonV2: no"
```

Save as `bin/zen-gen.sh`; run at session start to bind recipes to reality.

## References

- [AMD PPR Family 17h Models 01h/08h (Zen 1) doc 54945](https://www.amd.com/content/dam/amd/en/documents/)
- [AMD PPR Family 1Ah Model 00h-0Fh (Zen 5) doc 58550](https://www.amd.com/content/dam/amd/en/documents/epyc-technical-docs/programmer-references/58550-0.01.pdf)
- [Chips and Cheese — Discussing AMD's Zen 5 at Hot Chips 2024](https://chipsandcheese.com/p/discussing-amds-zen-5-at-hot-chips-2024)
- [Chips and Cheese — Zen 4 Hot Chips 2023](https://chipsandcheese.com/p/hot-chips-2023-characterizing-gaming-workloads-on-zen-4)
- [Linux kernel tools/perf/pmu-events/arch/x86/amdzen{1-5}/](https://github.com/torvalds/linux/tree/master/tools/perf/pmu-events/arch/x86/)
- [LIKWID Zen Doxygen](https://rrze-hpc.github.io/likwid/Doxygen/zen.html)
- [LIKWID Zen 4 wiki](https://github.com/RRZE-HPC/likwid/wiki/Zen4)
- [LWN — AMD UMC perf events](https://lwn.net/Articles/946708/)
- [Phoronix — Linux 6.7 Perf Events AMD UMC](https://www.phoronix.com/news/Linux-6.7-Perf-Events)
- [Phoronix — AMD Zen 5 Perf Events Linux 6.13](https://www.phoronix.com/news/AMD-Zen-5-Perf-Events-Linux-613)
