# Decisions

Architecture decisions and code reuse log. Newest first.

## Template
### YYYY-MM-DD — Title
- **Decision:**
- **Why:**
- **Alternatives considered:**
- **Reuse (if any):** repo · commit SHA · license · files · what changed

---

### 2026-10-08 — Phase 1–3 complete on `phase-1`; final measurements
- **Decision:** The bundle target is now ≤ 8 MB universal.
- **Measured** (Release, ~1,050 processes, 30 s cputime delta):
  - Bundle: 7.0 MB = binary 5.2 MB + asset catalog 1.2 MB + helper 0.4 MB.
  - CPU: 0.56% with the window hidden, 1.16% with it visible.
  - Footprint: 21 MB.
  - Tests: 226.
- **Why:** The full Phase 2/3 feature set landed (inspector, ports, launchd, helper, history, alerts). No PNG optimizer is installed, and installing one is left to the product owner (pngquant would save about 0.8 MB on the icon).
- **Alternatives considered:** Dropping Intel (the SPEC requires it); `-Osize` (0.4 MB, slower hot path).

### 2026-10-08 — Details tree view, inspector windows, tree kill in menus
- **Decision:** Tree is a toggle in the Details toolbar (outline column = Name, nodes expanded by default, the user's collapses are remembered by `NodeID`). Natural tree order is start time within siblings (shown as the Start time sort); sorting another column is the only thing that reorders. Search keeps ancestors of matches. Flat/tree switch does one bulk reload via `TableFeed.requestReload()`. Context menus gained "End process tree" (single selection, `ProcessActionCenter.requestEndTree`) and "Properties…" (⌘I, double-click in Details). The inspector is one `NSWindow` per process (`InspectorWindows`), data read once on open and on Refresh; only the header CPU/memory follows the visible snapshot.
- **Why:** Windows Task Manager / Process Explorer feel without per-tick row jumps; no per-tick inspector work.
- **Alternatives considered:** tree in Processes tab (it already groups by app); sheet instead of windows (only one at a time).

### 2026-10-08 — Size and overhead targets revised after Phase 2/3
- **Decision:**
  - **Bundle size:** the universal app bundle target is now ≤ 6 MB including the helper. It is 4.9 MB measured without the helper: 3.5 MB binary + 1.2 MB asset catalog. The earlier < 3 MB target predates Phase 2/3.
  - **CLI:** the `proclens` CLI (2.8 MB) is not embedded in the app; it ships separately via Homebrew.
  - **Overhead budget:** < 1% CPU applies to background operation (window hidden, menu bar only), measured at 0.36–0.53%. With the window visible at 1 s and ~1,050 processes, ~1.1–1.9% is accepted for now. Footprint is ~21 MB after `Sampler.history` stopped retaining full process tables (was 72–80 MB).
- **Why:**
  - Real features (inspector, launchd, history, alerts) roughly doubled the code.
  - `-Osize` saved only 0.4 MB and slows the hot path.
  - In visible mode, the full sampler (~0.9%) plus the table redraw is a floor at 1 s sampling.
- **Alternatives considered:**
  - `-Osize` for everything.
  - Shipping arm64 only (SPEC requires Intel support).
  - A 2 s default interval. Rejected for now: Windows Task Manager parity uses 1 s, and users can pick 2 s.

### 2026-10-08 — Menu bar: own NSStatusItem + NSPopover, throttled bitmap graph
- **Decision:** `MenuBarExtra` is replaced by `StatusItemController` (`MenuBarViews.swift`): an `NSStatusItem` whose button gets a pre-tinted bitmap (24 CPU bars + optional percentage), and an `NSPopover` (transient, no animation) that hosts the existing `MenuBarContent` / `QuickPanel` with the same `.processActionConfirmation(actions)` host. The popover content is created on open and freed on close; `model.setPanelOpen(false)` runs in `popoverDidClose`. The graph is redrawn at most every 1.5 s (bars advance two samples at a time at 1 s sampling) and only when a bar height or the text changed; the item has a fixed length. The image is redrawn when the button's `effectiveAppearance` changes. "Open ProcLens" / Settings go through `WindowOpener` (`showSettingsWindow:` for Settings). `AppModel.start()` now runs from `App.init`, not from the window's `.task`, so sampling and the graph never depend on the window existing. Also: `NSWindow.isRestorable = false` on the main window (AppKit's restoration flush re-snapshots the window and showed up in profiles), the Processes totals strip is plain `NSTextField`s updated in place instead of a SwiftUI view, and `AppModel.history` no longer keeps process tables.
- **Why:** Hidden-window CPU was 1.16%, dominated by `MenuBarExtra` re-laying out and re-rendering its label for every new `NSImage` (AppKit `_updateReplicants`, appearance and layout work). Measured, Release, 30 s cputime delta: SwiftUI label 1.16%, direct `button.image` every tick ~0.7-1.0%, redraw every 1.5 s ~0.36%, no redraw at all 0.16% (floor).
- **Alternatives considered:** layer-backed `NSView` / `CAShapeLayer` inside the button (tried: 18-26% CPU, because the status item replicant snapshot software-renders the whole layer tree via `renderInContext` on every change); template image (costlier to draw than a pre-tinted one); keeping `MenuBarExtra` and only throttling (still pays SwiftUI label diffing and layout per redraw).
- **Open:** `ProcLensCore.Sampler` keeps its own 60-snapshot ring (`history`, only used by tests) including every process table: ~13-17 MB at 1,055 processes. The app does not read it. Not touched here (Core is out of scope for this change); dropping `processes` from that ring, or making it optional, is the largest remaining footprint win.

### 2026-10-08 — Phase 3 core: bounded history, alert engine, `proclens` CLI
- **Decision:**
  - `History/ProcessHistory` (actor, in-memory only, nothing persisted; starts empty each launch). System totals (cpu, memory used, disk r+w, network rx+tx physical, gpu) at 1 s for 10 min and as 10 s buckets (mean + peak) for 1 h. Per 10 s bucket only the union of top 20 by CPU and top 20 by memory is stored (pid, start time, interned name index, cpu mean as Float, memory peak): at most 40 x 32 B x 360 buckets. `spikes` uses the bucket **peak** so a 1 s spike is not averaged away; `topProcesses(at:)` returns the nearest bucket (half-open, boundary belongs to the later one) including the still-open one. `series(for:)` only has points where the process was in a top list. An open-bucket accumulator (one entry per live process) is the only per-process state over the whole table and is discarded every 10 s. Measured estimate (MemoryLayout strides x counts, test `memoryStaysUnderSixMegabytesForAnHourOf1050Processes`): ~0.8 MB for 1 h at 1,050 processes (budget 6 MB). Names are interned and compacted past 4,096.
  - `Alerts/`: `AlertRule` (Codable; target anyProcess/systemTotal/process(name, exact|contains, case-insensitive); metric cpu % (100 = one core), memory MiB, energy score; `atLeast`; duration; cooldown), `AlertEngine` actor (state per rule x ProcessID or system; timers use snapshot instants; once per episode; cooldown suppresses and a still-sustained condition fires when it ends; vanished process resets its timer, keeps its cooldown; snapshots missing the needed data are skipped without reset; `evaluate` returns events and also yields on an `AsyncStream`), `AlertRuleStore` (versioned JSON, atomic write, injectable URL, default `~/Library/Application Support/ProcLens/alert-rules.json`). No UserNotifications here; the app posts them.
  - CLI: SPM library `ProcLensCLIKit` (parser, row types, JSON/CSV/table rendering, commands behind an injectable `CLIIO`) + a thin executable `proclens`. No dependencies, hand-rolled parser. Exit codes 0 ok / 1 error / 2 usage / 3 refused. `kill` uses `ProtectionPolicy` (pid <= 1 refused before any lookup) and `TreeKiller` for `--tree`. Documented in `docs/CLI.md`.
- **Why:** SPEC §7 and the §2 budget: recording costs one dictionary update per process per tick; storage is a small constant. The CLI shares the collectors, so numbers match the app; moving logic out of `main.swift` makes it unit-testable.
- **Alternatives considered:** per-process full-resolution series (about 1,000 x 3,600 samples, tens of MB); storing only means for system buckets (hides short spikes); swift-argument-parser (forbidden, no dependencies); SQLite/on-disk history (more code, privacy surface, not asked); re-firing every cooldown while a condition persists (notification spam).
- **Caveats:** `proclens` reports itself in `ps` (its own sampling shows briefly). `top` row limit is `--limit` (not in the brief). Window is 10 s buckets, so "what spiked at 14:32" resolves to 10 s.

### 2026-10-08 — Launchd + Login Items core, privileged helper protocol
- **Decision:**
  - `Launchd/` in Core: `LaunchdPlistScanner` (5 plist dirs, Apple dirs read-only; invalid plists collected separately; signing via `CodeSignatureInspector` on demand), `LaunchdDirectoryWatcher` (FSEvents -> `AsyncStream`), `LaunchctlRunning` + `ProcessLaunchctlRunner` (timeout), `LaunchctlPrintParser` (`list`, `print <domain>` services table, `print <domain>/<label>`, `print-disabled`), `LaunchdService` actor (merge + actions), `BackgroundItemsParser` (`sfltool dumpbtm`), `OwnLoginItem` (`SMAppService.mainApp`).
  - Merge rule: override database (`print-disabled`) wins over the plist `Disabled` key; "loaded" = present in `launchctl list` (gui) or in the services table of `launchctl print system` (system domain; readable without root, one call instead of one per job).
  - Gui-domain actions run `/bin/launchctl` directly with target `gui/<uid>/<label>`; system-domain actions go through `PrivilegedLaunchdActions` (helper), default "Requires the ProcLens helper". Items under /System are refused for every action.
  - New SPM target `ProcLensHelperProtocol` (Foundation only): XPC protocol (`ProcLensHelperXPC`, Data requests/replies so no NSSecureCoding classes), Codable models, `HelperPolicy` allowlists (verbs enable/disable/bootstrap/bootout/kickstart[-k]/kill; system domain only; labels `[A-Za-z0-9._+@-]`, never `com.apple.*` or the helper; bootstrap only for plists directly in /Library/LaunchDaemons; signals HUP/INT/QUIT/KILL/TERM/STOP/CONT/USR1/USR2; pid <= 1 and the helper itself refused; start-time check against pid reuse), and a shared blocking `SubprocessRunner`.
  - Helper sources live in top-level `ProcLensHelper/` and are also compiled by SwiftPM through a symlink `ProcLensCore/Sources/ProcLensHelper`. Client requirement: `anchor apple generic and identifier "com.canberkki.ProcLens" and certificate leaf[subject.OU] = "<team>"`; team = `TEAMID_PLACEHOLDER` replaced by release.sh, else the helper's own signing team; none -> refuse all connections.
- **Why:** D4 (on-demand `launchctl`/`sfltool` only). Putting the allowlist in a Foundation-only module makes the security-relevant logic unit-testable without signing and shared by app (early reject) and helper (enforcement).
- **Alternatives considered:** one `launchctl print` per job (hundreds of spawns); AppleScript admin prompt for system actions (LaunchManager's approach, no stable identity); `SMJobBless` (deprecated); shell strings to the helper (injection surface).
- **Caveats:** the BTM fixture follows the documented layout of `sfltool dumpbtm` (needs root; could not be captured here, `dumpbtm` also hangs without a TTY/auth), so re-validate against a real dump once the helper runs signed. The XPC connection, `SMAppService.daemon` registration and client validation cannot be tested unsigned.
- **Reuse:** Sean10000/LaunchManager · edd75d922a54c10da0d638779471e93a1dece377 · MIT · Services/PlistService.swift (scanAll/scanDirectory/parsePlist), Models/LaunchItem.swift, Models/InvalidPlist.swift, Services/DirectoryWatcher.swift, Services/LaunchctlService.swift (verbs, list/print-disabled parsing) → Launchd/LaunchdItem.swift, LaunchdPlistScanner.swift, LaunchdDirectoryWatcher.swift, LaunchctlParsers.swift, LaunchdService.swift · kept the plist keys, scan loop, FSEvents setup and the launchctl verb set; dropped SwiftUI/localised strings, plist writing/cloning/deleting and AppleScript privilege; added Sendable value types, read-only Apple scopes, AsyncStream, typed parsers, helper routing. xModern54/Task-Manager-MacOS (no license): approach only, no code.

### 2026-10-08 — Phase 2 Core: inspector, ports, dev-server rules, tree kill
- **Decision:**
  - `FDSource` / `RegionSource` / `ProcessController` protocols wrap libproc and `kill`; the live implementations use `PROC_PIDLISTFDS`, `PROC_PIDFDVNODEPATHINFO`, `PROC_PIDFDSOCKETINFO`, `PROC_PIDFDPIPEINFO`, `PROC_PIDREGIONPATHINFO` and `PROC_PIDTBSDINFO` only. No shelling out, no private API.
  - `FileDescriptorInspector` and `LoadedImagesInspector` are on-demand actors. Loaded images are files mapped into the process; dyld shared-cache libraries appear only as the cache file (limitation, documented in the type).
  - `ListeningPortCollector` (`.everyN(2)`, also callable via `scan(table:)`) keeps TCP LISTEN and unconnected UDP sockets with a non-zero local port. It skips `isRestricted` processes, caches "no sockets / unreadable" per `ProcessID` for 5 runs, and merges helper-provided ports (`setHelperPorts`). Measured on this Mac: 1,089 processes (375 restricted) = 1.5 ms cold, 0.9 ms warm.
  - `dev-server-rules.json` gained container, Django, Flask, Uvicorn, Gunicorn, FastAPI, Jupyter, PHP built-in server, Hugo, Jekyll, Puma, Storybook and cargo-watch rules, an `httpPorts` list, and a `word` flag so short needles (`bun`, `next`, `node`...) match whole tokens only. The first matching rule wins; the list is ordered most specific first.
  - `ProcessTree` is built once per table: a parent must exist and must not have started after its child (pid reuse); cycles are broken by promoting the oldest unvisited node to a root. `TreeKiller` sends SIGTERM children-first, polls for a grace period, then SIGKILLs survivors. It re-checks each pid's start time before signalling, treats zombies as dead, refuses the whole operation if the root is refused by `ProtectionPolicy`, and skips refused descendants.
  - Address formatting is our own `inet_ntop` wrapper (`AddressFormatter`, v4-mapped IPv6 shown as IPv4). sloth's `IPUtils.m` was not adapted.
- **Why:** SPEC §6 items 1-3; keeps per-tick cost low and every syscall mockable.
- **Alternatives considered:** `lsof -i` (forbidden); caching ports across ticks without re-reading socket owners (stale listeners); substring-only needles (false positives such as `bundle` matching `bun`).
- **Reuse:** timdreesen/simple-dev-server-viewer · b578c10c3a45895443a1dfea278462b5908d6c8e · MIT · src-tauri/src/lib.rs `classify()` rules extended in `dev-server-rules.json` (data) and `collect_descendants()` → `Actions/TreeKiller.swift` (algorithm only: BFS descendants, children first; grace/escalation is our own).

### 2026-10-08 — Small binary, no third-party dependencies; D3 revised
- **Decision:** The shipped app has no SPM dependencies. Release builds strip all symbols and use dead-code stripping and whole-module optimization. Target: universal bundle < 3 MB (it was 3.6 MB at the first UI build). **D3 is revised:** the global hotkey uses our own small Carbon `RegisterEventHotKey` wrapper instead of `KeyboardShortcuts`.
- **Why:** The product owner requires a small, handy app. One hotkey doesn't justify a dependency, its UI and its maintenance.
- **Alternatives considered:** `KeyboardShortcuts` (MIT); `-Osize` (rejected because CPU budget comes first).

### 2026-10-08 — Menu bar quick panel
- **Decision:** The MenuBarExtra becomes a `.window`-style panel with these parts:
  - compact CPU/Memory/GPU/Network gauges and 60 s sparklines
  - a search field (name or PID)
  - the top 5 processes by CPU or memory, with End task / Force quit
  - an "Open ProcLens" button
  - an optional "Hide Dock icon" setting

  The process list is computed only while the panel is open. Phase 2 adds listening dev-server ports with tree kill.
- **Why:** Quick access is the most frequent use of a task manager. It also showcases the port/dev-server differentiator.
- **Alternatives considered:** A plain menu, which offers no search or kill; a separate floating window, which is heavier.

### 2026-10-08 — Kill UX is Windows-like
- **Decision:** These ways to act on a process all go through `ProtectionPolicy` and a confirmation sheet:
  - right-click menu: End task (Quit), Force quit, Suspend/Resume, Reveal in Finder, Copy PID/path
  - Delete key = End task
  - typing a PID in search finds it
  - ⌘K opens "End process by PID"
- **Why:** This is the product owner's requirement, and it matches Windows Task Manager muscle memory.
- **Alternatives considered:** Toolbar-only actions (slower).

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

### 2026-10-08 — Self-overhead: hidden window = light sampler, cached rows, feed bypasses SwiftUI
- **Decision:** (1) `AppModel` tracks window visibility (occlusion/miniaturize/app hidden). While hidden it stops the full `Sampler` and runs a CPU+memory-only `Sampler` (shared collectors) so only the menu bar graph keeps updating; window views observe `visibleSnapshot`, which freezes while hidden. `PROCLENS_FORCE_VISIBLE=1` disables the gating for profiling on a covered/asleep screen. (2) `ProcessesViewModel` caches per-process static data (group, owner, display/sort key, tooltip) and the formatted row, keyed by a quantized signature; rows are rebuilt only when the signature changes; name sort uses a precomputed 8-byte rank; collapsed groups/apps are not rebuilt (children frozen until expanded). (3) Rows reach the `NSOutlineView` through a `TableFeed` (no SwiftUI body re-evaluation per tick), `beginUpdates` is only issued for structural changes, changed visible cells are refreshed in place. (4) Menu bar image is rendered once into a bitmap and reused while unchanged. (5) Workspace launch/terminate notifications are debounced and only invalidate caches when the regular-app set changes.
- **Why:** SPEC budget < 1% CPU at 1 s sampling with 1,000+ processes. Profiling showed per-tick sorting/formatting of ~1,000 rows, full-table diffs and a redrawn status item dominated the UI cost, and the full collectors ran even with the window hidden.
- **Alternatives considered:** Pausing the Core sampler entirely when hidden (loses the menu bar graph); virtualised cell formatting (bigger rewrite, not needed yet); changing `ProcessCollector` (remaining floor is ~2 syscalls per process per tick, left alone).
