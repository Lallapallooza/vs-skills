# Install & Troubleshooting — AMD uProf on Linux

AMD uProf is distributed as a proprietary tarball (EULA-gated) or as official RPM/DEB packages on supported distros. Officially supported OSes in uProf 5.x: Ubuntu 22.04+, RHEL 8.6+, SLES, openSUSE Leap 15.5, Debian 12, Rocky 9.3, Alma Linux 9.4, FreeBSD 14 (PCM only). Any distro outside that matrix is out-of-spec — works in practice but you may need to adapt install steps and patch compatibility issues yourself.

This reference covers:
- Install paths per distro.
- The `perf_event_paranoid` matrix.
- Known uProf 5.x bugs with workarounds.
- Secure Boot / lockdown caveats.
- Cloud-EPYC specific problems.

## Download

AMD gates downloads behind a EULA form — there is no stable URL for direct fetching. One-time manual step:

1. Visit https://www.amd.com/en/developer/uprof.html
2. Accept the EULA.
3. Download `AMDuProf_Linux_x64_<version>.tar.bz2` (~300 MB) or the distro-specific `.rpm` / `.deb`.

For scripted provisioning, store the tarball in a team artifact repository (e.g., internal Artifactory) with the EULA accepted once.

## Install paths

### Ubuntu / Debian (.deb)

```bash
sudo apt install ./amduprof_<version>_amd64.deb
# Installs to /opt/AMDuProf_Linux_x64_<version>/
# Adds AMDuProfCLI, AMDuProfPcm, AMDuProfSys, AMDuProfCfg to PATH via wrappers in /usr/local/bin/
# DKMS builds the Power Profiler Driver automatically
```

### RHEL / Rocky / Alma / Fedora (.rpm)

```bash
sudo rpm -ivh amduprof-<version>.x86_64.rpm
# Same layout as DEB; DKMS auto-builds the kernel module
```

### Tarball (universal fallback for any distro)

```bash
# Extract
tar xjf AMDuProf_Linux_x64_<version>.tar.bz2 -C /opt/
cd /opt/AMDuProf_Linux_x64_<version>/

# Optional: install the Power Profiler Driver (needed for power timechart / roofline)
sudo ./bin/AMDPowerProfilerDriver.sh install

# Put on PATH (example)
export PATH="$PATH:/opt/AMDuProf_Linux_x64_<version>/bin"
```

On distros that don't match AMD's linker/FHS expectations, binaries may fail to start because of library linkage. Common remedies:

- **Non-FHS distros**: wrap the tarball in a sandbox/FHS-compatible environment with Qt5, X11, libstdc++, zlib, zstd, elfutils, ncurses, fontconfig, freetype, libGL, libxkbcommon, the X11/XCB set, and a `libtinfo.so.5 → libtinfo.so.6` symlink. Qt5 is required even for CLI-only invocation.
- **Custom distros / minimal containers**: install Qt5 + the X11/XCB stack even if running headless — AMDuProfCLI's shared-library resolution scans them at startup.
- **Unofficial packages** (e.g., community AUR packages): may lag kernel API changes; pin to a known-working version or patch locally.

### Containers

Running uProf inside a container works if:
- `--privileged` or appropriate capabilities (`CAP_SYS_ADMIN`, `CAP_PERFMON`).
- `/sys/kernel/debug`, `/proc/kcore` mounted read-only if you need kernel profiling.
- Host kernel modules (`amd_uncore`, `msr`, Power Profiler Driver if needed) loaded on the host.
- `--cap-add SYS_ADMIN` is often the minimum for IBS.

Minimal Dockerfile stanza (Debian-based):
```dockerfile
RUN apt-get update && apt-get install -y libqt5core5a libxcb1 libxcb-util1 \
    libxcb-image0 libxcb-keysyms1 libxcb-render-util0 libxcb-icccm4 \
    libxkbcommon-x11-0 libgl1 libfontconfig1 libfreetype6 libtinfo6
COPY AMDuProf_Linux_x64_<version>.tar.bz2 /tmp/
RUN tar xjf /tmp/AMDuProf_Linux_x64_<version>.tar.bz2 -C /opt/ && \
    ln -sf /opt/AMDuProf_Linux_x64_<version>/bin/AMDuProfCLI /usr/local/bin/
ENV LD_LIBRARY_PATH=/opt/AMDuProf_Linux_x64_<version>/bin:/opt/AMDuProf_Linux_x64_<version>/lib/x64/shared
```

## perf_event_paranoid matrix

```bash
cat /proc/sys/kernel/perf_event_paranoid
```

| Value | Non-root can | Blocks |
|---|---|---|
| 4 | (nothing) | all perf access for non-root |
| 3 (Debian 12 default) | (nothing meaningful) | system-wide, IBS, kernel samples |
| 2 (kernel upstream default) | user-mode counters on own tasks | system-wide, kernel samples, **IBS** |
| 1 (often Ubuntu default) | + IBS on own tasks, kernel samples on own tasks | system-wide |
| 0 | + system-wide; IBS system-wide | raw tracepoints for non-root |
| -1 | + raw tracepoints | (nothing) |

**Impact:**
- For IBS in a uProf session on your own workload (non-root), need `<= 1`.
- For `AMDuProfCLI collect -a` (system-wide) or `AMDuProfPcm -a`, need `<= 0` or `sudo`.

**Temporary override:**
```bash
sudo sysctl -w kernel.perf_event_paranoid=1
```

**Persistent:** edit `/etc/sysctl.d/` or the distro-equivalent:
```
# /etc/sysctl.d/99-perf.conf
kernel.perf_event_paranoid = 1
```
Then `sudo sysctl --system`. For dev machines, 1 is reasonable; for shared systems, leave at 2 and use `sudo` for profiling sessions.

## NMI watchdog

Consumes 1 of the 6 GP PMCs. AMD's uProf docs recommend disabling for profile sessions:

```bash
# Temporary
sudo sysctl -w kernel.nmi_watchdog=0

# Persistent via sysctl
# /etc/sysctl.d/99-perf.conf
kernel.nmi_watchdog = 0

# Or via kernel command line (more thorough, requires bootloader edit)
# Add to GRUB_CMDLINE_LINUX: nmi_watchdog=0
```

Also needed for AMDuProfPcm roofline — roofline requires all 6 counters and fails with "NMI watchdog is enabled. NMI uses one Core HW PMC counter. Please disable NMI watchdog."

## CPU frequency governor

Performance mode gives reproducible numbers. Otherwise, `amd-pstate` can drift frequency mid-workload and distort timer / event-count ratios.

```bash
# Check current governor
cpupower frequency-info -p

# Set to performance (temporary)
sudo cpupower frequency-set -g performance

# Verify turbo / actual freq during workload
turbostat --Summary --quiet -i 1 -n 30
```

Persistent across distros: most use `cpupower.service` or `tuned` profiles; some have `/etc/default/cpupower`. On systemd-based distros:
```
# /etc/systemd/system/cpupower.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/cpupower frequency-set -g performance
```

`amd-pstate` modes (Zen 3+ CPPC):
- `passive` — kernel governors (acpi-cpufreq style)
- `active` — CPPC hardware-autonomous (recommended for modern Zen)
- `guided` — kernel sets range, hardware chooses

Verify with:
```bash
cat /sys/devices/system/cpu/amd_pstate/status
# active | passive | guided | disable
```

## Required kernel modules

```bash
# Verify presence
lsmod | grep -E 'amd_uncore|amd_energy|msr'
```

- **`amd_uncore`** — exposes DF/L3/UMC PMUs. Needed for `perf stat -e amd_df/...`, `amd_umc_*`. Load: `sudo modprobe amd_uncore`.
- **`msr`** — direct MSR read/write. Needed for uProf MSR-mode collection (not for the default Perf-mode).
- **`amd_energy`** (optional) — hwmon driver for RAPL energy. Exposes `/sys/class/hwmon/hwmonN/energy*_input`.

Most modern distros auto-load these on AMD hardware. If missing, add to the module-load list (varies per distro).

## Secure Boot / kernel lockdown

With Secure Boot + lockdown integrity mode, unsigned kernel modules cannot load. The AMD Power Profiler Driver is proprietary + unsigned.

**Symptom:** `AMDuProfCLI timechart` or `AMDuProfPcm -m power` fails; `dmesg` shows module signature rejected.

**Fix:** add `--use-linux-perf` to all uProf invocations. Routes through in-tree perf, no driver needed. Cost: power timechart and roofline are unavailable (those specifically need the driver for RAPL sampling).

Alternative: disable lockdown (not recommended; undoes Secure Boot's value). Or sign the module yourself using MOK (Machine Owner Key) — see your distro's Secure Boot module-signing docs.

## Known uProf 5.x bugs — workarounds

From AMD's own release notes ([docs.amd.com 63856](https://docs.amd.com/r/en-US/63856-uProf-release-notes/)) and 4.1 release notes. Not exhaustive — check the current release notes page for anything new.

| Bug | Workaround |
|---|---|
| `0x80004005` — "driver failed to start profiling" | Add `--use-linux-perf` to collect. If still fails, the proprietary driver isn't loaded / is broken. |
| `0x8000ffff` on 1-event collect | `ulimit -n 65535` before collect (fd limit). |
| GUI crash on AWS Genoa VM + Hyper-V | CLI only. Cloud EPYC + GUI is a known-broken combination. |
| AMDuProfPcm on Azure: only package 0 DF metrics | Documented limitation. Run `perf stat -e amd_df/...` manually per socket as workaround. |
| Turin Dense + Hyper-V: wrong topology | Skip per-CCD attribution in virt; report socket-level only. |
| Translate hangs 4-6 h on large MPI (>200 GB raw) | Reduce rank count; shorter collection duration. |
| Ctrl-C during `report --symbol-server` crashes + corrupts session | Don't use `--symbol-server` unattended. |
| Timer event + Custom filter → GUI crash | Avoid combo. |
| IBS Fetch "extremely low" samples on Zen 1/2 | Use IBS Op for front-end questions on those generations. |
| IBS + TBP/EBP in custom config → silent sample drop | Never combine. IBS alone, or standard `assess`/`tbp` separately. |
| IBS + MPI → huge datasets | Run IBS per-rank sequentially. |
| MPI report volume not evenly split across ranks | Cross-check with `mpi_profile` or `tau` for quantitative byte-count. |
| OpenMP >1M parallel regions → callstack stitching fails | Increase `AMDUPROF_MAX_PR_INSTANCES` env var. |
| Sleep/hibernate mid-profile freezes timechart | Prevent power events during profile (inhibit sleep, pin workload). |
| `LD_LIBRARY_PATH` not inherited under uProf | Pass library paths explicitly or use LD_PRELOAD; report as bug if blocking. |
| Dynamic libs "not recognized" | Confirm debuginfo is present; try `--use-linux-perf` (different codepath). |
| Kernel 6.16 DKMS build fails (`vm_flags` API change) | Apply community patch: `vm_flags_set(vma, VM_RESERVED)` at `PwrProfSharedMemOps.c:222`; or stick on kernel ≤6.15 for power profiling until AMD ships update. |
| `sysconf(83)` bug (legacy 4.1.x, unverified on 5.2.606) | If `0x80004005` with driver loaded, hex-patch `libAMDCpuProfilingRawData.so` at offset ~0x0000AC80 from `bf 53 00 00 00` → `bf 54 00 00 00`. Test before trusting on 5.x. |

## Cloud EPYC caveats

| Platform | Known issue | Workaround |
|---|---|---|
| AWS EC2 EPYC (m7a, c7a, r7a) | uProf GUI crashes; Power Profiler Driver may not load on Nitro | `--use-linux-perf` + CLI only |
| Azure HBv4, HX, Dasv5 (EPYC) | AMDuProfPcm reports only package 0 DF metrics | Per-socket manual perf stat |
| GCP C3D (EPYC) | Partial (not tested exhaustively per uProf 5.x notes) | Canary first; fall back to perf |
| Hetzner AX-series (bare-metal EPYC) | Generally works | Standard Linux setup applies |
| Nested virt (VirtualBox, QEMU without PMU passthrough) | IBS disabled | Pass PMU through to guest, or profile on host |

Cloud EPYC rule of thumb: **always `--use-linux-perf`**; **always canary collect** before relying on results; power timechart + roofline often fail on cloud due to driver issues, so use bare metal when those metrics are needed.

## Debugging a broken install

Checklist in order:

1. **Binary exists and runs.**
   ```bash
   which AMDuProfCLI; AMDuProfCLI --version
   ```

2. **Kernel paranoid level ok.**
   ```bash
   cat /proc/sys/kernel/perf_event_paranoid   # want <= 1 for IBS
   ```

3. **`amd_uncore` module loaded.**
   ```bash
   lsmod | grep amd_uncore
   # If missing: sudo modprobe amd_uncore
   ```

4. **NMI watchdog off (for roofline).**
   ```bash
   cat /proc/sys/kernel/nmi_watchdog
   ```

5. **Canary collection succeeds.**
   ```bash
   AMDuProfCLI collect --config tbp -o /tmp/canary /bin/ls
   echo "exit: $?"
   ls /tmp/canary/
   ```

6. **If canary fails:**
   - Try `--use-linux-perf`.
   - Try as root.
   - Try `-V/--verbose` to see which step fails.

7. **If driver-specific features fail (power timechart):**
   - Check `dmesg | grep -i 'power.*profiler\|amdpowerprofiler\|signature rejected'`.
   - Accept that power metrics require the proprietary driver; if unavailable, substitute `perf stat -e power/energy-pkg/` or `turbostat`.

8. **If Rust/Go symbols are mangled:**
   - Rust: `RUSTFLAGS="-C symbol-mangling-version=v0 -C force-frame-pointers=yes"`.
   - Go: ensure debug info in binary; try `perf` instead of uProf for Go (better ecosystem support).

9. **If callstacks are missing frames:**
   - Confirm `-g -fno-omit-frame-pointer` in build.
   - Try `--call-graph dwarf` (needs `-g` DWARF info).
   - For deep callstacks on Zen 4+, try `--call-graph lbr`.

10. **If results disagree between uProf and perf:**
    - Check IBS vs PMC counts (IBS is IP-precise but count-imprecise).
    - Check `%enabled` / `%running` in perf stat output (multiplexing).
    - Cross-check wall-clock time with `hyperfine`.

## When to give up on uProf and use perf

- Kernel DKMS module fails and `--use-linux-perf` is insufficient for your needs (you specifically need power timechart or roofline).
- Cloud EPYC with persistent GUI / topology bugs.
- The uProf session hangs or outputs nonsense numbers repeatedly.
- You need per-cgroup / per-container scoping.

All of these cases, `perf` + samply/hotspot is the answer. See [perf-complements.md](perf-complements.md).

## Uninstall

```bash
# RPM/DEB
sudo apt remove amduprof    # or sudo rpm -e amduprof

# Tarball
sudo rm -rf /opt/AMDuProf_Linux_x64_<version>/
sudo rm -f /usr/local/bin/AMDuProf*

# Unload/remove the DKMS kernel module
sudo dkms remove AMDPowerProfiler/<version> --all
```

## References

- [AMD uProf User Guide — docs.amd.com 57368](https://docs.amd.com/r/en-US/57368-uProf-user-guide/)
- [AMD uProf 5.x release notes — docs.amd.com 63856](https://docs.amd.com/r/en-US/63856-uProf-release-notes/)
- [AMD uProf 4.1 release notes PDF (acknowledged limitations)](https://www.amd.com/content/dam/amd/en/documents/developer/version-4-1-documents/uprof/release-note-uprof-v4.1.pdf)
- [AMD Profiling-Support-on-Linux-for-perf_event_paranoid-Values](https://docs.amd.com/r/en-US/57368-uProf-user-guide/Profiling-Support-on-Linux-for-perf_event_paranoid-Values)
- [AMD Operating-Systems (5.x support matrix)](https://docs.amd.com/r/en-US/57368-uProf-user-guide/Operating-Systems)
- [kernel.org — amd-pstate driver admin guide](https://www.kernel.org/doc/html/latest/admin-guide/pm/amd-pstate.html)
- [kernel.org — perf-security](https://www.kernel.org/doc/html/v5.1/admin-guide/perf-security.html)
