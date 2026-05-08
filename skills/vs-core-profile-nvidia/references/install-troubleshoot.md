# Install & Troubleshooting — NVIDIA Profilers on Linux

Currency: as-of 2026-04. CUDA 13.2 / driver 580+ / nsys 2026.2 / ncu 2026.1.1 baseline. Older toolkit/driver matrix at the bottom.

Nsight Systems and Nsight Compute ship with the CUDA Toolkit on Linux (`nsys`, `ncu` binaries) and as standalone DEB/RPM/run-installer packages. The profilers' main failure mode is not install — it's **permissions, container caps, MIG/MPS state, and CUDA-toolkit-driver mismatches**. This reference covers:

- CUDA toolkit / driver / Nsight version compatibility.
- The `NVreg_RestrictProfilingToAdminUsers` / `ERR_NVGPUCTRPERM` matrix.
- Compute mode, persistence, lock clocks.
- MIG / MPS / Confidential Computing (silent counter loss).
- Container caps (Docker, k8s, vGPU).
- Cloud GPU caveats (AWS, GCP, Azure, WSL, Jetson).
- Known Nsight bugs with workarounds.
- "When to give up on Nsight Compute" — the route to nsys + cudaEvents instead.

## Install paths

### Standalone installs (recommended — newer than CUDA Toolkit bundle)

```bash
# Nsight Systems — pick latest from https://developer.nvidia.com/nsight-systems
# .deb (Debian/Ubuntu)
sudo apt install ./NsightSystems-linux-public-2026.2.x.deb
# .rpm (RHEL/Rocky/SUSE)
sudo rpm -ivh nsight-systems-2026.2.x.x86_64.rpm
# Generic .run (any distro)
sudo bash NsightSystems-linux-public-2026.2.x.run

# Nsight Compute — https://developer.nvidia.com/nsight-compute
sudo apt install ./nsight-compute-2026.1.1.deb
# OR
sudo bash nsight-compute-linux-2026.1.1.run
```

Both install to `/opt/nvidia/nsight-systems/<ver>/` and `/opt/nvidia/nsight-compute/<ver>/` with symlinks to `/usr/local/bin/{nsys,ncu,ncu-ui}`.

### From CUDA Toolkit bundle

```bash
# Ubuntu/Debian
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
sudo apt install cuda-toolkit-13-2     # nsys + ncu included

# Verify
which nsys ncu ncu-ui
nsys --version  # 2026.2 with CUDA 13.2
ncu --version   # 2026.1.1 with CUDA 13.2
```

**Standalone vs toolkit:** the standalone Nsight versions ship later than the bundle. For the latest features (especially Blackwell metrics, NCCL `--communicator shmem`), prefer standalone.

## CUDA / driver / Nsight compatibility matrix

CUDA libraries are **forward-compatible** with newer drivers but **not backward-compatible** with older ones. The CUPTI specifically: *"New versions of CUPTI are not backwards compatible with older versions of the CUDA driver."* — [CUPTI usage docs](https://docs.nvidia.com/cupti/main/main.html). Symptom of mismatch: `CUPTI_ERROR_NOT_INITIALIZED (15)`.

| CUDA Toolkit | Min driver (Linux) | nsys | ncu | Notes |
|---|---|---|---|---|
| 12.0 | 525.60.13 | 2022.5 | 2022.4 | Hopper baseline; no Blackwell |
| 12.4 | 550.54.14 | 2024.1 | 2024.1 | FP8 metrics on Hopper |
| 12.6 | 560.28.03 | 2024.5 | 2024.3 | PM Sampling Hopper hang fix (2024.3.1) |
| 12.8 | 570.86.10 | 2025.1 | 2025.1 | PC Sampling + concurrent kernels same pass; B200 metric support added |
| 13.0 | 575.51.x | 2025.3 | 2025.4 | **Activity-API PC Sampling REMOVED**; nvprof/nvvp REMOVED; consumer Blackwell sm_120 |
| 13.2 | 580.x | 2026.2 | 2026.1.1 | NCCL `--communicator shmem` for NCU |

**Diagnostic for mismatch:**

```bash
# Driver vs runtime
nvidia-smi | grep "Driver Version"
nvcc --version | grep release

# Runtime CUPTI version (libcupti)
ldd $(which python3) | grep cupti
strings /usr/local/cuda/lib64/libcupti.so.* | grep -i "cupti.*version" | head -3

# When stale libcupti is on LD_LIBRARY_PATH (common from old conda envs)
find / -name "libcupti.so*" 2>/dev/null  # find all candidates
echo $LD_LIBRARY_PATH | tr ':' '\n' | xargs -I{} ls {}/libcupti* 2>/dev/null
```

If `LD_LIBRARY_PATH` pulls a stale `libcupti` from an old conda/venv, profiling will fail with `CUPTI_ERROR_NOT_INITIALIZED`. Fix: prepend `/usr/local/cuda/lib64`.

## Permissions: `NVreg_RestrictProfilingToAdminUsers`

The single most common profiling failure on Linux. Symptom:

```
==ERROR== ERR_NVGPUCTRPERM - The user does not have permission to access NVIDIA GPU Performance Counters on the target device 0.
```

Or:

```
==WARNING== Profiling kernels launched by root is not supported on the system.
```

### History

- **Driver 419.17+ (Windows) / 418.43+ (Linux)** added `NVreg_RestrictProfilingToAdminUsers=1` as default. Applies to ALL profilers using CUPTI (Nsight Compute, Nsight Systems with `--gpu-metrics-devices`, anything calling Counter/Range Profiler API).
- **Source:** [ERR_NVGPUCTRPERM Solution](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters).

### Check current state

```bash
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
# 0 = anyone can profile (preferred for dev hosts)
# 1 = root or CAP_SYS_ADMIN only (default)
```

### Permanent fix (Linux)

```bash
# /etc/modprobe.d/profile.conf
cat <<'EOF' | sudo tee /etc/modprobe.d/nvidia-profile.conf
options nvidia "NVreg_RestrictProfilingToAdminUsers=0"
EOF

# Rebuild initrd
# Debian/Ubuntu:
sudo update-initramfs -u -k all
# RHEL/Rocky/Alma/Fedora:
sudo dracut --regenerate-all -f
# Arch:
sudo mkinitcpio -P

# Reboot to apply
sudo reboot
```

### Temporary fix (no reboot)

Stop everything using the GPU first (X, all CUDA processes), then:

```bash
sudo systemctl stop display-manager  # or `sudo systemctl stop gdm3` etc.
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia NVreg_RestrictProfilingToAdminUsers=0
```

### When the fix doesn't take

Symptom: applied modprobe option, rebooted, still `ERR_NVGPUCTRPERM`. Causes documented in [NVIDIA forum 275131](https://forums.developer.nvidia.com/t/err-nvgpuctrperm-fixes-failing-for-non-admin-users/275131):

1. **`nouveau` took over after reboot.** `lsmod | grep nouveau`. Blacklist via `/etc/modprobe.d/blacklist-nouveau.conf` then rebuild initrd.
2. **Multiple modprobe configs conflicting.** `grep -r RmProfiling /etc/modprobe.d/` — there should be one entry.
3. **DKMS rebuild needed after kernel upgrade.** `sudo dpkg-reconfigure nvidia-dkms-<ver>` (Debian) or `sudo dnf reinstall nvidia-driver` (RHEL).
4. **Driver 545.x + RHEL 8.8 known issue:** `cap_sys_admin` capability alone is insufficient ([forum 280223](https://forums.developer.nvidia.com/t/ncu-returns-err-nvgpuctrperm-for-cap-sys-admin-users/280223)). Use root or full `--privileged` container.

### Containers

```bash
# Docker — minimum for ncu
docker run --rm --gpus all \
  --cap-add=SYS_ADMIN \
  -v $PWD:/work -w /work \
  nvidia/cuda:13.2.0-devel-ubuntu22.04 \
  ncu --section SpeedOfLight ./app

# If --cap-add SYS_ADMIN insufficient (RHEL 8.8 + driver 545+):
docker run --rm --gpus all --privileged ...

# Kubernetes — typically can't grant SYS_ADMIN; must change host modprobe
# OR use a privileged DaemonSet (security tradeoff)
```

**Rule:** the modprobe flag must be set on the **host kernel**, not in the container. The container can never override this. If the host runs `RmProfilingAdminOnly=1`, you need root + `SYS_ADMIN` (or `--privileged`) inside.

## Compute mode

```bash
nvidia-smi -q -d COMPUTE
```

Modes:
- **`DEFAULT` (0):** multiple processes can use the GPU. Recommended for profiling.
- **`EXCLUSIVE_PROCESS` (1):** one process at a time. ncu will fail if another process holds the device.
- **`PROHIBITED` (2):** no compute. Profiling impossible.

Set: `sudo nvidia-smi -c 0`.

## Persistence mode (Linux)

```bash
sudo nvidia-smi -pm 1  # enable
sudo nvidia-smi -pm 0  # disable
```

Persistence mode keeps the driver loaded between CUDA contexts, eliminating the ~1-second cold-start latency. **Always enable for benchmarking** — without it, the first iteration includes driver-init time, polluting the warmup. Note: not persistent across reboot. To make it persistent:

```bash
# /etc/systemd/system/nvidia-persistenced.service comes with the driver
sudo systemctl enable nvidia-persistenced
sudo systemctl start nvidia-persistenced
```

## Lock clocks (reproducibility)

GPU clock varies with thermals, power budget, and DVFS. For reproducible counter values lock clocks:

```bash
# List supported clock pairs
nvidia-smi --query-supported-clocks=gr,mem --format=csv

# Lock GPU clock (Volta+, root)
sudo nvidia-smi -lgc <freq>           # single freq
sudo nvidia-smi -lgc <min>,<max>      # range (boost within)

# Lock memory clock (pre-Hopper)
sudo nvidia-smi -lmc <freq>

# Hopper/Blackwell: -lmc doesn't work, use deferred:
sudo nvidia-smi --lock-memory-clocks-deferred=<min>,<max>

# Reset to default
sudo nvidia-smi -rgc -rmc
```

For long-running benchmarks, lock to base or boost depending on whether you want average-realistic or peak numbers. NCU's `--clock-control base` does this internally per-launch but **not on MIG instances** (see below).

## MIG (Multi-Instance GPU)

MIG partitions an A100/H100/H200/B200 into up to 7 isolated GPU instances. Profiling is supported per-instance, with constraints documented in [NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html):

1. **`ncu` cannot lock clocks on MIG.** *"On Multi-Instance GPU (MIG) configurations, NVIDIA Nsight Compute cannot lock clocks anymore. Users are expected to lock clocks externally using nvidia-smi."* `--clock-control` will fail with: *"Attempting to use the `--clock-control` option to set the GPU clocks will fail when profiling on a MIG GPU partition."*
   **Workaround:** `sudo nvidia-smi -lgc base,boost` on the parent device before starting the MIG instance.
2. **Concurrent workloads on the same MIG slice corrupt metrics.** *"profiling a kernel while any other GPU work is executing on the same MIG compute instance can result in varying metric values for all units... GPU work issued through other APIs in the target process or workloads created by non-target processes running simultaneously in the same MIG compute instance will influence the collected metrics."*
   **Workaround:** isolate the slice — stop DCGM exporters, monitoring agents, sidecar containers; ensure single workload per slice.
3. **Shared-unit metrics not collectible.** Metrics from GPU units shared between MIG instances cannot be collected per-instance. Only "exclusively owned" units' metrics are accessible.

```bash
# Check MIG state
nvidia-smi -q -d MIG

# List instances
nvidia-smi mig -lgi

# Profile inside an instance — set CUDA_VISIBLE_DEVICES to MIG UUID
export CUDA_VISIBLE_DEVICES=MIG-<uuid>
ncu --set full ./app
```

## MPS (Multi-Process Service)

```bash
# Check
ls /tmp/nvidia-mps 2>/dev/null && echo "MPS server running"
```

**`ncu` does not support MPS profiling** ([NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html)): *"Profiling with enabled multi-process service (MPS) is not supported."*

Workarounds:
- Stop the MPS daemon for the profile, profile a single process, restart MPS:
  ```bash
  echo quit | nvidia-cuda-mps-control
  ncu --set full ./app
  nvidia-cuda-mps-control -d
  ```
- Move workload to a non-MPS host.
- For multi-tenant inference (the typical MPS case), use DCGM (continuous fleet telemetry) or PyTorch profiler (per-process) instead.

`nsys` works under MPS but kernels from all clients show in the timeline; use NVTX domains to disambiguate.

## Confidential Computing (CC) mode

Hopper H100 and later support CC mode, which encrypts CPU↔GPU traffic. **Profiling counters are disabled** as a side-channel mitigation:

```bash
nvidia-smi conf-compute -f
# Enabled = profiling NOT supported
```

NCU 2025.4 Known Issues: *"Profiling is not supported while the target GPU is configured to run in any Confidential Computing mode."*

Workaround: disable CC for the profiling node, or profile on a non-CC twin instance.

## Cloud GPU caveats

| Platform | Known issue | Workaround |
|---|---|---|
| AWS p4d / p4de (A100) | Generally works; `--cap-add SYS_ADMIN` for ncu in Docker | Standard setup |
| AWS p5 / p5e (H100 80GB) | Standard EC2; verify driver ≥ 535 for Hopper full features | Standard setup |
| AWS p5en (H200) | H200 SXM with 4.8 TB/s; nsys 2024.5+ for full HBM3e metrics | Use standalone Nsight |
| AWS g5 / g5g (A10G/Grace) | A10G not as well-supported in some metric sets | Verify metrics with `--query-metrics --chip ga102` |
| GCP A3 (H100 SXM5) | Standard | — |
| GCP A3 Mega / Ultra (H100/H200) | NVLink topology may differ from on-prem; verify with `nvidia-smi topo -m` | — |
| Azure ND H100 v5 / v6 | Standard | — |
| Azure ND MI300X | AMD; out of scope (not this skill) | — |
| **vGPU** (Tesla M60/T4/A100 vGPU mode, Citrix, VMware) | Live-migration not supported; NVLink metrics unavailable; **unlicensed = silent throttle** | Verify license with `nvidia-smi -q \| grep License`; switch to bare-metal for profiling |
| **WSL2** (Windows 11 + Linux) | Requires WSL2 + driver 525+ + Windows 11 ([forum 260814](https://forums.developer.nvidia.com/t/error-profiling-is-not-supported-on-device-0-as-it-uses-the-windows-subsystem-for-linux-wsl/260814)) | Boot native Linux for profiling on Win10 |
| **Jetson Orin / Thor** | `nsys --gpu-metrics-devices` NOT supported ([forum 288503](https://forums.developer.nvidia.com/t/nsys-does-not-support-gpu-metrics-device-for-jetson-agx-orin/288503)); use `tegrastats` for system metrics | `tegrastats` + `ncu` |
| GCP / Azure with **Spot/Preemptible** instances | Spot interruption mid-profile loses partial trace | Save reports often (`--export sqlite`) |
| **MIG-only EC2 / GCP flavors** | Smaller flavors expose only one MIG slice; MIG profiling rules apply | See MIG section above |

**vGPU unlicensed silent throttle:** [NCU 2025.4 known issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html): *"As of CUDA 11.4 and R470 TRD1 driver release, NVIDIA Nsight Compute is supported in a vGPU environment which requires a vGPU license. ... If the license is not obtained after 20 minutes, the reported performance metrics data from the GPU will be inaccurate because of a feature in vGPU environment which reduces performance but retains functionality."* This is silent — your numbers will look plausible but be wrong.

Cloud rule of thumb: **always canary** with `ncu --section SpeedOfLight /bin/true` before relying on results; verify license on vGPU; prefer bare-metal for power/clock-sensitive measurements.

## DCGM and Nsight Systems compete for sampling

Symptom: `nsys profile --gpu-metrics-devices=all` reports "Some GPUs are not supported" or shows empty metric tracks. Cause: **DCGM and Nsight Systems share the same hardware sampling infrastructure**.

Fix from [NVIDIA forum 294781](https://forums.developer.nvidia.com/t/issue-with-gpu-metrics-collection-for-nvidia-a100-on-nsight-systems/294781): tear down the DCGM **DaemonSet**, not just the service:

```bash
# Kubernetes (where dcgm-exporter typically runs)
kubectl delete daemonset dcgm-exporter -n <ns>  # or `prometheus`, `monitoring`, etc.

# Bare-metal
sudo systemctl stop nvidia-dcgm
sudo systemctl stop dcgm-exporter
```

Then run nsys. Restart DCGM after profiling.

## Known Nsight Compute bugs — workarounds

From [NCU release notes](https://docs.nvidia.com/nsight-compute/ReleaseNotes/) and known-issues archives. Not exhaustive — check current release notes for anything new.

| Bug / symptom | Cause | Workaround | Status |
|---|---|---|---|
| `ncu` hangs on NCCL collective kernels ([NCCL #466](https://github.com/NVIDIA/nccl/issues/466)) | Default kernel-replay serializes mandatory-concurrent kernels | `--communicator shmem` for same-process tree (NCU 2026.1 release notes); `--communicator tcp` is in the CLI accepted-values list for cross-process but only `shmem` was highlighted in the release-note prose — canary first; otherwise skip and use `nsys` | Fixed-with-flag in 2026.1 for shmem; older = hang |
| `ncu` reports kernel order differently than execution | Per-launch measurement overhead alters scheduling; NVIDIA staff: "the tool has to do work at the point where the kernel is launched" | Use `nsys` for end-to-end timing; ncu only for counter values ([forum 272056](https://forums.developer.nvidia.com/t/why-does-ncu-perform-global-serialized-execution-for-all-current-kernels-during-kernel-replay/272056), felix_dt Nov 2023) | Documented behavior |
| PM Sampling on Hopper hangs application | Pre-2024.3.1 bug | Upgrade ncu ≥ 2024.3.1 | Fixed |
| PM Sampling timeline distorted (initial samples corrupted) | Pre-2025.4.1 bug | Upgrade ncu ≥ 2025.4.1; or discard first sample window | Fixed |
| PM Sampling not supported with Profile Series | NCU 2025.4 known issue | Use counter-only sections for Profile Series | Current |
| PM Sampling multi-pass timeline misaligned | Hardware constraint | Use range replay (single pass per range) | Current |
| `ncu` cannot lock clocks on MIG | Hardware constraint | `nvidia-smi -lgc` on parent | Current |
| MPS profiling not supported | Hardware constraint | Stop MPS for profile | Current |
| Confidential Computing on → counters disabled | Side-channel mitigation | Disable CC | Current |
| `--cap-add SYS_ADMIN` insufficient on RHEL 8.8 + driver 545.x | Driver-distro interaction | Use `--privileged` container | Current per [forum 280223](https://forums.developer.nvidia.com/t/ncu-returns-err-nvgpuctrperm-for-cap-sys-admin-users/280223) |
| Range replay + multiple Green Contexts → counters aggregated | NCU 2025.4 known issue | Profile one Green Context at a time | Current |
| FP8 numbers low; kernel name says E4M3 | Silent fallback to BF16 SASS ([flash-attention #1848](https://github.com/Dao-AILab/flash-attention/issues/1848)) | `cuobjdump --dump-sass` to verify; not a profiler bug | User error |

## Known Nsight Systems bugs — workarounds

| Bug / symptom | Cause | Workaround | Status |
|---|---|---|---|
| `nsys` segfault with NCCL 2.14.3 ([NCCL #785](https://github.com/NVIDIA/nccl/issues/785)) | Regression after NCCL 2.10.3 | Use NCCL ≥ 2.18.x; or older 2.10.x | Reported, fix-in-flight |
| `nsys` hangs with `NCCL_P2P_USE_CUDA_MEMCPY=1` on H800 ([NCCL #1480](https://github.com/NVIDIA/nccl/issues/1480)) | Specific env var triggers driver-side hang | Unset `NCCL_P2P_USE_CUDA_MEMCPY` for profiling | Open |
| `nsys --gpu-metrics-devices` not supported on Jetson Orin | Hardware constraint | Use `tegrastats` | Current |
| WSL: "Profiling is not supported on device 0 as it uses the Windows Subsystem for Linux" on Win10 | WSL2 needs Win11 + driver 525+ | Boot native Linux | Current |
| `verl` + Ray + nsys gpu-metrics fails ([verl #2438](https://github.com/verl-project/verl/issues/2438)) | Container + Ray worker init order | Set `--gpu-metrics-devices=all` only in main process; or skip per-rank | Open |
| GPU metrics randomly drop near short kernels at high freq ([forum 363103](https://forums.developer.nvidia.com/t/nsight-systems-gpu-metrics-become-unaligned-or-empty-near-a-short-kernel-at-higher-sampling-frequencies/363103)) | High-freq sampling races with short kernels | Lower `--gpu-metrics-frequency` (e.g., 10000 → 5000) | Open |
| nsys + DCGM running → "Some GPUs not supported" | Shared sampling infrastructure | Stop DCGM (incl. K8s DaemonSet) | Documented |
| `--cuda-graph-trace=node` overhead very high | CUDA graphs node-level trace records every node | Default `--cuda-graph-trace=graph` for routine profiling; node only when investigating graph internals | Documented |

## When to give up on Nsight Compute

Stop trying to make `ncu` work and use alternatives in these cases:

1. **NCCL or any cross-stream overlap is the question.** Even with `--communicator shmem` (NCU 2026.1+), the replay distortion makes overlap claims unreliable. Use `nsys` + cudaEvents.
2. **MPS-shared GPU.** Not supported. Stop MPS for the profile or use DCGM/PyTorch profiler.
3. **Multi-tenant Kubernetes without admin.** Can't change host modprobe; can't run `--privileged`. Use DCGM (no permission needed for `DCGM_FI_PROF_*`) or PyTorch profiler.
4. **Confidential Computing on.** Counters off; can't profile. Move to non-CC.
5. **vGPU without license.** Numbers silently degraded. Move to bare-metal.
6. **Hopper/Blackwell async kernels (FA3, CUTLASS Ping-Pong) where overlap is the main interest.** ncu serializes; use `nsys` + cudaEvents.
7. **You need per-cgroup or per-container scope.** ncu has none. Use `nsys` (which can attach per-pid) or framework-internal metrics (PyTorch/JAX/Triton autotune logs).

In all of these, `nsys` + `cudaEvent` timing + framework metrics give you what `ncu` can't.

## Debugging a broken install — checklist

1. **`nvidia-smi` works, shows GPUs.**
   ```bash
   nvidia-smi
   ```
2. **CUDA toolkit installed and on PATH.**
   ```bash
   which nvcc; nvcc --version
   ```
3. **Nsight binaries on PATH.**
   ```bash
   which nsys ncu ncu-ui
   nsys --version; ncu --version
   ```
4. **`libcupti` resolvable to current CUDA's version.**
   ```bash
   ldconfig -p | grep cupti
   ```
5. **`/proc/driver/nvidia/params` shows `RmProfilingAdminOnly: 0`** (or you're root).
   ```bash
   cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
   ```
6. **No competing telemetry running** (DCGM exporter, monitoring agents).
7. **Persistence on, clocks locked** (for stable benchmarking).
8. **Compute mode is DEFAULT** (or only your process holds the GPU).
9. **MIG/MPS state expected** (single tenant for ncu; MPS off for ncu).
10. **Canary works.**
    ```bash
    nsys profile --trace=cuda --stats=true -o /tmp/c1 /bin/true && echo "nsys ok"
    ncu --section SpeedOfLight -o /tmp/c2 /bin/true && echo "ncu ok"
    ```

If steps 1–10 all pass but profiling still fails, run with `--verbose` (nsys) or `--log-level trace` (ncu) and inspect the output. NVIDIA staff respond on developer forums to specific error logs.

## Uninstall

```bash
# Standalone Nsight Systems
sudo apt remove nsight-systems-2026.2  # or rpm -e
sudo rm -rf /opt/nvidia/nsight-systems/2026.2

# Standalone Nsight Compute
sudo apt remove nsight-compute-2026.1.1
sudo rm -rf /opt/nvidia/nsight-compute/2026.1.1

# CUDA Toolkit (removes nsys + ncu bundled)
sudo apt remove --purge cuda-toolkit-13-2

# Modprobe option (revert to admin-only profiling)
sudo rm /etc/modprobe.d/nvidia-profile.conf
sudo update-initramfs -u -k all  # or dracut
sudo reboot
```

## References

- [ERR_NVGPUCTRPERM Solution (NVIDIA)](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters)
- [Nsight Systems User Guide](https://docs.nvidia.com/nsight-systems/UserGuide/index.html)
- [Nsight Compute Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
- [NCU 2025.4 Known Issues](https://archive.docs.nvidia.com/nsight-compute/2025.4/ReleaseNotes/topics/known-issues.html)
- [NCU Release Notes (current)](https://docs.nvidia.com/nsight-compute/ReleaseNotes/)
- [CUPTI Release Notes (forward-only compatibility)](https://docs.nvidia.com/cupti/release-notes/release-notes.html)
- [NCCL #466 — ncu hangs collectives](https://github.com/NVIDIA/nccl/issues/466)
- [NCCL #785 — nsys segfault NCCL 2.14.3](https://github.com/NVIDIA/nccl/issues/785)
- [NCCL #1480 — nsys hang NCCL_P2P_USE_CUDA_MEMCPY](https://github.com/NVIDIA/nccl/issues/1480)
- [Forum 272056 — ncu kernel replay reorders execution](https://forums.developer.nvidia.com/t/why-does-ncu-perform-global-serialized-execution-for-all-current-kernels-during-kernel-replay/272056)
- [Forum 229127 — Docker ERR_NVGPUCTRPERM](https://forums.developer.nvidia.com/t/cant-use-nsight-compute-in-nvidia-docker-container/229127)
- [Forum 280223 — cap_sys_admin insufficient RHEL 8.8](https://forums.developer.nvidia.com/t/ncu-returns-err-nvgpuctrperm-for-cap-sys-admin-users/280223)
- [Forum 275131 — modprobe fix breaks driver](https://forums.developer.nvidia.com/t/err-nvgpuctrperm-fixes-failing-for-non-admin-users/275131)
- [Forum 324409 — `--privileged` works](https://forums.developer.nvidia.com/t/root-user-ncu-error-no-permission-to-access-gpu-performance-counters/324409)
- [Forum 260814 — WSL2 unsupported on Win10](https://forums.developer.nvidia.com/t/error-profiling-is-not-supported-on-device-0-as-it-uses-the-windows-subsystem-for-linux-wsl/260814)
- [Forum 288503 — nsys --gpu-metrics-device not supported on Orin](https://forums.developer.nvidia.com/t/nsys-does-not-support-gpu-metrics-device-for-jetson-agx-orin/288503)
- [Forum 363103 — nsys gpu-metrics drop near short kernels](https://forums.developer.nvidia.com/t/nsight-systems-gpu-metrics-become-unaligned-or-empty-near-a-short-kernel-at-higher-sampling-frequencies/363103)
- [Forum 294781 — A100 GPU metrics fails because of DCGM](https://forums.developer.nvidia.com/t/issue-with-gpu-metrics-collection-for-nvidia-a100-on-nsight-systems/294781)
- [Forum 358159 — nvprof/nvvp deprecated](https://forums.developer.nvidia.com/t/announcement-cuda-nvprof-and-visual-profiler-are-deprecated/358159)
- [Dao-AILab/flash-attention #1848 — FP8 silent fallback](https://github.com/Dao-AILab/flash-attention/issues/1848)
- [verl #2438 — Ray + nsys gpu-metrics fails](https://github.com/verl-project/verl/issues/2438)
