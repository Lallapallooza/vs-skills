# Lock and fingerprint protocol

*Level: loop-kernel (universal across archetypes and target types).*

Two harness-owned mechanisms that together prevent the most common silent-corruption failure modes:

1. **Lock** on the measurement primitive. Prevents two iters from running concurrently and corrupting each other's measurements.
2. **Environment fingerprint** at iter start. Detects when the host has drifted in a baseline-affecting way since the last `keep`.

Both are mandatory. Both are harness-owned (the agent never writes lock files or fingerprints).

## Lock primitive

Default: `flock(2)` with `LOCK_EX`. Wrapper script form:

```
lock_path=/var/lock/autoloop-<measurement-primitive>.lock
exec flock -n -E 200 "$lock_path" "$@"
# exit code 200 = lock held by another process (mapped to verdict=crash, description=lock_held)
```

Properties:

- **Per-measurement-primitive, not per-instance.** Two instances that share the same measurement primitive (e.g., two perf-tuning loops on the same bench binary) share the same lock and serialize.
- **Dies with the process.** No leak on crash; the kernel releases the lock when the holding process exits.
- **Non-blocking acquisition.** The wrapper fails fast (`flock -n`) if the lock is held. The execution driver retries on the next tick.

### Stronger variants

For more isolated environments:

- **systemd transient unit**: `systemd-run --user --scope --slice=autoloop-<primitive>.slice <command>`. Provides single-instance + cgroup membership. Combined with `cpuset.cpus.partition=isolated`, this is the production pattern for benchmark farms.
- **cgroup v2 partition**: dedicates CPU and memory resources to the iter; isolates from the rest of the system.

The instance declares its lock variant at scaffold time. Default is `flock`; users with stricter isolation needs (shared CI hosts, multi-tenant servers) opt into the systemd variant.

### What the lock does NOT cover

- **SMT siblings.** A `taskset -c 0` run is poisoned by whatever runs on the SMT sibling thread. The lock does not see siblings. The instance must declare SMT-related preconditions (e.g., "SMT off" or "siblings reserved") in `MANDATES.md`.
- **Background kernel threads.** IRQ handlers and kthreads pinned to the bench cores can poison measurements. The instance's pre-iter check should assert that the affinity mask excludes them.
- **Memory pressure from other processes.** If the host is swapping or page-cache-thrashing, the bench numbers degrade. The fingerprint catches large drifts; small ones are absorbed by the noise floor.
- **Network or disk contention.** Same; instance-specific. The fingerprint should include relevant counters.

## Environment fingerprint

A JSON object capturing every input to the measurement that could change since the last `keep`. Emitted by the harness at iter start; compared to the most recent `keep`'s manifest.

If the fingerprint has drifted in any **baseline-affecting** field, the iter emits `discard_environment_changed` and stops. The renderer requires a re-baseline before any new comparison.

### Fingerprint fields (universal)

```json
{
  "timestamp_utc": "<ISO-8601>",
  "host": {
    "hostname": "<string>",
    "kernel_version": "<uname -r>",
    "kernel_cmdline": "<contents of /proc/cmdline>",
    "uptime_seconds": <int>
  },
  "cpu": {
    "model": "<from cpuinfo>",
    "cores_online": <int>,
    "smt_enabled": <bool>,
    "isolated_cpus": "<string>"  // from /sys/devices/system/cpu/isolated
  },
  "frequency_governance": {
    "governor": "<performance | powersave | ...>",
    "boost": <bool>,
    "min_freq_khz": <int>,
    "max_freq_khz": <int>
  },
  "memory": {
    "total_kb": <int>,
    "thp_state": "<always | madvise | never>",
    "swap_used_kb": <int>
  },
  "process_environment": {
    "concurrent_pids": [<int>, ...],  // ps snapshot at iter start
    "load_avg": [<1m>, <5m>, <15m>]
  },
  "toolchain": {
    "compiler_version": "<string>",
    "linker_version": "<string>",
    "lib_versions": { "<name>": "<version>", ... }
  },
  "instance_specific": {
    // declared per instance at scaffold time; e.g., AGESA on AMD hosts,
    // microcode revision, hypervisor info, container runtime version
  }
}
```

The instance can extend `instance_specific` with whatever its measurement primitive depends on. The schema is open at that field; it's frozen everywhere else.

### Drift classification

Not all fingerprint changes invalidate the baseline. The harness classifies fields:

- **Baseline-affecting**: any change requires re-baseline. Examples: kernel version, CPU model, frequency governor, SMT state, compiler version, instance-declared dependencies.
- **Informative-only**: changes are logged but don't invalidate. Examples: timestamp, uptime, load_avg, concurrent_pids (unless an instance declares otherwise).

The classification per-field is declared in the manifest schema. The agent does not classify; the harness does.

### What re-baseline means

When fingerprint drift triggers re-baseline:

1. The harness pauses idea selection.
2. The next iter runs the noise-floor calibration (see [`noise-floor-calibration.md`](noise-floor-calibration.md)) under no-change conditions on the new host state.
3. Once calibration completes, the new noise floor is appended as a `[kind=noise-recalibration]` Decision Log entry in `mission.md`.
4. The active target's baseline measurement is re-captured and stored.
5. Idea iteration resumes against the new baseline.

This is the only way to compare numbers across host states honestly.

## Concurrent-process snapshot

The `concurrent_pids` field records `ps` output at iter start. Purpose:

- Detect that another bench process is running (the lock should have caught this, but `ps` is a second line of defense).
- Detect long-running tasks that pre-date the lock (e.g., a sanitizer test suite started before the lock was claimed).
- Correlate slow-mode iters with specific concurrent processes after the fact.

The instance can declare a list of "poisonous concurrent processes" — if any of these PIDs appear in the snapshot, the iter aborts as `discard_guard` with `description=concurrent_poison:<pid_list>`.

## Implementation notes

The fingerprint emit script is a 50-line shell script. It writes one JSON file. It does not depend on any libraries beyond standard Linux utilities.

The fingerprint compare script is similarly small. It reads two JSON files and emits a diff classified by drift category.

Both scripts live in the harness, not in `MANDATES.md`. The `MANDATES.md` *references* them; the user does not edit them per-instance.

Per-instance customization happens through:
- The `instance_specific` field of the manifest schema.
- The classification rules (what counts as baseline-affecting).
- The list of poisonous concurrent processes.
