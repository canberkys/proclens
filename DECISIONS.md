# Decisions

Architecture decisions and code reuse log. Newest first.

## Template
### YYYY-MM-DD — Title
- **Decision:**
- **Why:**
- **Alternatives considered:**
- **Reuse (if any):** repo · commit SHA · license · files · what changed

---

### 2026-10-08 — Device collectors: GPU, disk and network from public APIs only
- **Decision:** `LiveIORegistrySource` reads `IOAccelerator` → `PerformanceStatistics` (`Device Utilization %`, fallback `GPU Activity(%)`) and `IOBlockStorageDriver` → `Statistics` (`Bytes (Read)` / `Bytes (Write)`, id = registry entry ID). `LiveNetworkSource` walks `sysctl NET_RT_IFLIST2` `if_msghdr2` records (64-bit counters). `DiskCollector` and `NetworkCollector` turn counters into bytes/s using the tick `instant`; first sample, new device or a decreasing counter gives zero for that device, loopback is excluded, vanished devices are pruned. `GPUCollector` is a passthrough.
- **Why:** The aggregate numbers need no DiskArbitration (physical drives, volumes and mounts are not needed for throughput). Per-device zeroing avoids spikes from counter resets or hot-plugged disks and interfaces.
- **Alternatives considered:** stats' DiskArbitration/`getDeviceIOParent` path (more code, same totals); IOReport and SMC for GPU power/temperature (private, excluded per REUSE_PLAN 1.7); `getifaddrs` (32-bit counters wrap).
- **Reuse:** exelban/stats · ee4265f3b9afdffebd3273cf6a83b9327ead45b5 · MIT · Modules/GPU/reader.swift (InfoReader.read), Modules/Disk/readers.swift (ActivityReader), Modules/Net/readers.swift (getBytesInfo) → LiveIORegistrySource.swift, LiveNetworkSource.swift, GPUCollector.swift, DiskCollector.swift, NetworkCollector.swift · kept the property keys and the sysctl record walk; dropped IOReport/SMC, DiskArbitration, nettop, CoreWLAN, public IP; added unaligned reads, IOObjectRelease on every object, delta/prune logic.

### 2026-10-08 — Host collectors: reuse from exelban/stats; logical CPU order is efficiency-first
- **Decision:** `LiveHostSource` (Mach `host_processor_info`, `host_statistics64`, sysctl), `CPUCollector` and `MemoryCollector` adapt stats' `LoadReader` and `UsageReader`. Core kinds come from `hw.perflevelN`, assigned from the highest level index down: logical CPUs are numbered least-performant first (E cores, then P cores). If the level counts don't sum to the core count, kinds are `.unknown`. Page counts use the kernel page size (16 KiB on Apple Silicon), via `host_page_size`.
- **Why:** Verified on this Mac (4 Efficiency + 10 Performance, `hw.perflevel0` = Performance): IORegistry `cpu0`-`cpu3` have `cluster-type` E and `cpu4`-`cpu13` P. stats reads the same per-cpu IORegistry order. The mapping uses only public sysctls.
- **Alternatives considered:** IORegistry `cluster-type` per core (what stats does; more code, same answer); assuming P-first (wrong on this hardware).
- **Reuse:** exelban/stats · ee4265f3b9afdffebd3273cf6a83b9327ead45b5 · MIT · Modules/CPU/readers.swift (LoadReader.read), Modules/RAM/readers.swift (UsageReader.read) → LiveHostSource.swift, CPUCollector.swift, MemoryCollector.swift · kept only the syscalls and tick/page extraction; dropped Reader/Store/NSLock/hyperthread folding, ran as actors over `HostSource`, cached the host port, handled 32-bit tick wrap.

### 2026-10-08 — Resolved REUSE_PLAN open decisions D1–D4
- **Decision:**
  - D1: the Energy column is an approximate score from `rusage_info_v6`, labelled as an approximation.
  - D2: per-process Network and GPU columns are hidden and marked "Phase 2". There is no `nettop` in Phase 1.
  - D3: the global hotkey uses `sindresorhus/KeyboardShortcuts` (MIT, SPM), added at the hotkey step.
  - D4: the Services list and third-party Login Items come from on-demand parsing of `launchctl print` / `print-disabled` and `sfltool dumpbtm` (the latter via the helper), with fixture-tested parsers.
- **Why:** There is no public API for energy impact, per-process network/GPU, or launchd enumeration. These choices keep SPEC §2 (no shelling out on the hot path, no private APIs) intact for Phase 1 while still shipping the columns and tabs.
- **Alternatives considered:**
  - An opt-in `nettop` collector in Phase 1 (rejected for now; it bends §2).
  - Private `NetworkStatistics.framework` (rejected; private API).
  - A custom Carbon hotkey wrapper (more code to maintain).
  - Deprecated `SMCopyAllJobDictionaries` (incomplete).

### 2026-10-08 — Reuse: daemon name map and dev-server rules as JSON data
- **Decision:** Extracted lucid's process dictionary and simple-dev-server-viewer's classify() rules into bundled JSON resources.
- **Why:** Data reuse is cheapest (SPEC §3 rule 4); JSON is community-editable.
- **Alternatives considered:** Hand-written lists; keeping Swift literals.
- **Reuse:** tanRdev/lucid-task-manager · ee0bf35bae95a85c7bd373d1c419b058a6f443fd · MIT · ProcessDictionary.swift → daemon-names.json (literal → JSON, added section field) | timdreesen/simple-dev-server-viewer · b578c10c3a45895443a1dfea278462b5908d6c8e · MIT · src-tauri/src/lib.rs classify() → dev-server-rules.json (Rust tuples → JSON).

### 2026-10-08 — No code from TaskExplorer or xModern54/Task-Manager-MacOS
- **Decision:** Use both only as approach references. No code is copied.
- **Why:** TaskExplorer is GPL-3.0. xModern54/Task-Manager-MacOS has no license, so it is all rights reserved.
- **Alternatives considered:** None. SPEC §3 rule 2 forbids copying in both cases.

### 2026-10-08 — `launchctl` / `sfltool` only off the hot path
- **Decision:** Shelling out is allowed only for on-demand launchd actions and listings (enable/disable, kickstart, Services list, BTM dump). It is never used for periodic sampling.
- **Why:** There is no public API to enumerate launchd jobs or third-party login items. SPEC §2 forbids shelling out on the hot path only.
- **Alternatives considered:** Deprecated `SMCopyAllJobDictionaries`, which is incomplete. Private `xpc`/launch APIs are not approved.

### 2026-10-08 — Process identity = (pid, start time)
- **Decision:** Rows, diffs and history are keyed by `ProcessID(pid, startTime)`.
- **Why:** PIDs are reused. Keying by pid alone would attach a new process's history to a dead one and make rows jump.
- **Alternatives considered:** pid only; pid plus path, which is still ambiguous for re-exec.

### 2026-10-08 — Actor-based `Collector` protocol over mockable syscall sources
- **Decision:** Each collector is an `actor` conforming to `Collector`. It holds its previous sample for deltas and reads through a `Sendable` source protocol (`ProcessSource`, `HostSource`, `IORegistrySource`) with Live and Mock implementations. A `Sampler` actor drives ticks with a task group, fills ring buffers and publishes an `AsyncStream<SystemSnapshot>`.
- **Why:** This meets Swift 6 strict concurrency and keeps collection off the main thread. Tests run without real syscalls (SPEC §8).
- **Alternatives considered:** Porting stats' `Reader`/`Repeater` (GCD + NSLock, not Sendable); Combine publishers.

### 2026-10-08 — XcodeGen for the app project
- **Decision:** The app, helper and CLI targets are defined in `project.yml`. The `.xcodeproj` is generated and gitignored. `ProcLensCore` is a plain SPM package.
- **Why:** The project file stays diffable and reviewable. The helper embedding and signing settings live in text.
- **Alternatives considered:** A committed `.xcodeproj`, which merges poorly; SPM-only, which can't express helper embedding or `SMAppService` bundle layout cleanly.

### 2026-10-08 — No App Sandbox, direct distribution
- **Decision:** Ship outside the Mac App Store with Developer ID signing + notarization (DMG + Homebrew cask).
- **Why:** App Sandbox prevents enumerating other processes; TMOG hit the same wall and returned an empty process list when sandboxed.
- **Alternatives considered:** Mac App Store (not viable for a task manager).

### 2026-10-08 — Name: ProcLens
- **Decision:** Product name is ProcLens, following the Lens family (vLens, PkgLens).
- **Why:** Clear meaning (process lens), fits the family. A Linux kernel-module project of the same name exists on GitHub (navidpadid/ProcLens); different platform, acceptable.
- **Alternatives considered:** TaskLens (taken by an Obsidian plugin and an iOS app).
