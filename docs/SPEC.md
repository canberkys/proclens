# ProcLens — Specification

A native, sysadmin-grade Task Manager for macOS.
Part of the Lens family (vLens, PkgLens, ...).

## 1. Goal
Combine Windows 11 Task Manager's UX with Process Explorer-level depth and
launchd management in one native macOS app. Target users: power users,
sysadmins and developers who currently fall back to the terminal
(`top`, `lsof`, `launchctl`, `ps`).

Differentiator vs. existing tools (TMOG, "Task Manager for macOS", Stats,
TaskExplorer, LaunchManager): nobody combines Task Manager + process explorer
+ launchd manager + port/dev-server cleanup in a single sysadmin-focused tool.

## 2. Hard constraints
- Swift 6 (strict concurrency), SwiftUI; AppKit where SwiftUI is too slow
  (large tables → `NSTableView` via `NSViewRepresentable`).
- macOS 14+, Apple Silicon first, Intel supported.
- NOT sandboxed (App Sandbox blocks process enumeration). Distribution outside the
  App Store: Developer ID signing + notarization, DMG + Homebrew cask.
- Native APIs only on the hot path — never shell out to `ps`/`top`/`lsof`:
  - Processes: libproc (`proc_listallpids`, `proc_pidinfo` `PROC_PIDTASKALLINFO`,
    `proc_pidpath`, `proc_pid_rusage`), `sysctl KERN_PROCARGS2` for argv/env
  - Per-core CPU: `host_processor_info`; P/E core mapping via `sysctl hw.perflevel*`
  - Memory: `host_statistics64` (`HOST_VM_INFO64`); pressure via
    `DispatchSource.makeMemoryPressureSource`
  - GPU: IOKit `IOAccelerator` → `PerformanceStatistics`
  - Disk: IOKit `IOBlockStorageDriver` statistics
  - Network: `getifaddrs` / `sysctl NET_RT_IFLIST2`
  - Ports/sockets per process: `proc_pidinfo PROC_PIDLISTFDS` + `proc_pidfdinfo PROC_PIDFDSOCKETINFO`
  - Code signature: Security.framework `SecStaticCode` / `SecCodeCopySigningInformation`
  - Apps vs background: `NSWorkspace.shared.runningApplications`
- Sampling: 1s default (0.5 / 1 / 2 / 5 configurable). All collection off the main
  thread (actor-based collectors). UI updates diffed — no full-table reloads.
- Self-overhead budget: < 1% CPU, < 80 MB RAM at 1s sampling with 1,000+ processes.
  Measure it and show it in About.
- No telemetry. No network calls except the update check (automatic at most once a day, on by default, can be turned off in Settings; manual Check for Updates… always available).
- Private/undocumented APIs: only if explicitly flagged and approved, with a public fallback.

## 3. Reuse open-source code to move faster
Do not reinvent solved problems. Before implementing each collector or feature,
check these repos for a working implementation to adapt:

| Repo | Reuse candidate |
|---|---|
| github.com/exelban/stats (MIT) | CPU per-core, P/E cores, GPU (IOAccelerator), disk, network, sensor readers |
| github.com/tanRdev/lucid-task-manager (verify license) | 450+ macOS daemon → plain-English name map, safety categories |
| github.com/sveinbjornt/sloth (BSD — verify) | open files / sockets / pipes per process |
| github.com/Sean10000/LaunchManager (MIT) | LaunchAgent/Daemon parsing, launchctl load/unload, log viewing, listening-port scan |
| github.com/timdreesen/simple-dev-server-viewer (verify license) | dev-server / framework detection rules, process-tree kill (Rust → port logic to Swift) |
| "Task Manager for macOS" (MIT — locate repo via AlternativeTo) | Windows 11 layout, Details tab columns, Startup/Services pages |
| github.com/objective-see/TaskExplorer (verify license) | code-signature checks, dylib/file/network inspection |

Rules:
1. Clone each repo into `third_party/_reference/` (gitignored), read-only.
2. Before copying ANY code, read its LICENSE:
   - MIT / BSD / Apache-2.0 → OK to adapt; keep the original copyright header in the
     file and add an entry to `THIRD_PARTY_NOTICES.md`.
   - GPL / AGPL / LGPL / no license → do NOT copy code. Study the approach only and
     write our own implementation from scratch.
3. Adapt, don't paste: reused code must conform to our `Core` collector protocol,
   Swift 6 concurrency (actors, `Sendable`) and our tests. No vendoring of whole apps.
4. Prefer reusing data (e.g. the daemon name map) and small, self-contained readers
   over large UI code.
5. Every reused piece gets an entry in `DECISIONS.md`: source repo, commit SHA,
   license, files, what was changed.
6. If a maintained Swift package covers the need cleanly, prefer adding it via SPM.

## 4. Architecture
- `ProcLensCore` Swift package (no UI): collectors, models, ring buffers
  (60s / 10 min / 1 h history). One protocol per collector so it can be mocked.
  Fully unit-testable.
- `ProcLens` app target: SwiftUI views + `@Observable` view models.
- `ProcLensHelper` (Phase 2): privileged helper registered via `SMAppService.daemon`,
  XPC with strict client code-signature validation. Only for actions on root-owned
  processes and system-domain launchd jobs. Everything else works without an admin password.
- `proclens` CLI (Phase 3): shares `ProcLensCore`, JSON output for scripting.

## 5. Phase 1 — MVP (Windows Task Manager parity)
1. **Processes tab**: Apps / Background / System groups; columns CPU, Memory, Energy,
   Disk, Network, GPU; Windows-style heat-map coloring; sort, search, filter.
2. **Performance tab**: CPU (total + per-core grid, P/E distinguished), Memory
   (composition bar app/wired/compressed/cached + pressure), GPU, Disk, Network;
   60s live graphs.
3. **Details tab**: PID, PPID, user, arch (arm64 / x86_64 Rosetta), threads, ports,
   path, command line, start time, code-sign status. Column chooser.
4. **Actions**: Quit (`NSRunningApplication.terminate`), Force Quit (SIGKILL),
   Suspend/Resume (SIGSTOP/SIGCONT), Reveal in Finder, Copy path/PID.
   Confirm before killing. Refuse PID 0/1 and critical system processes with a clear message.
5. Configurable global hotkey (⌥⌘⎋ is taken by system Force Quit — choose another)
   + menu bar mini-graph.

## 6. Phase 2 — Sysadmin features (the differentiator)
1. Process tree view with stable layout (rows don't jump while updating; "tree lock").
2. Process inspector: open files, sockets, loaded dylibs, environment,
   signature/notarization, entitlements.
3. **Network Ports tab**: every listening TCP/UDP port → owning process; "open in browser"
   for localhost HTTP; detect dev servers (node, vite, next, python, docker) and kill
   the whole process tree.
4. **Startup tab**: Login Items (`SMAppService` status), `~/Library/LaunchAgents`,
   `/Library/LaunchAgents`, `/Library/LaunchDaemons`; show plist, program, enabled state,
   last exit status; enable/disable via `launchctl bootstrap/bootout`
   (helper for the system domain).
5. **Services tab**: launchd jobs (`launchctl print`-style info), status, PID, restart.
6. Plain-English names for common system daemons (bundled JSON map, community-editable).

## 7. Phase 3
- History: per-process CPU/RAM over 1 h, "what spiked at 14:32?" view.
- Alerts: threshold rules (process X > 80% CPU for 60s) → notification.
- `proclens` CLI + export (CSV/JSON).

## 8. Quality bar
- Unit tests for every collector (mocked syscalls) and the `KERN_PROCARGS2` parser.
- Benchmark target measuring collector cost with 1,000+ processes.
- Accessibility: VoiceOver labels, full keyboard navigation
  (Windows-like shortcuts, e.g. Delete = End task).
- Dark/light mode, follows system accent color.

## 9. Workflow
1. First, survey the reference repos and produce `docs/REUSE_PLAN.md`: for each
   Phase 1–2 feature, which repo/file we adapt (with license) or why we write it
   ourselves. Then propose folder structure, module boundaries and the collector
   protocol. Wait for approval before writing code.
2. Build Phase 1 step by step; after each step: build, run tests, short summary.
3. Never call private/undocumented APIs without flagging it and offering a public alternative.
4. Record every architectural choice and its reason in `DECISIONS.md`.
