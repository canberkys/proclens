# ProcLens — Reuse Plan

Survey of the reference repos from `docs/SPEC.md` §3, done 2026-10-08.
Clones live in `third_party/_reference/<owner>__<repo>` (gitignored, read-only),
checked out at the SHAs below. Licenses were read from each repo's LICENSE file.

## 1. Reference repos and licenses

| Repo | License | Commit | Code reuse allowed? | Notes |
|---|---|---|---|---|
| exelban/stats | MIT, © 2019 Serhiy Mytrovtsiy | `ee4265f3b9afdffebd3273cf6a83b9327ead45b5` | Yes | `Kit/lldb` is BSD-3 (LevelDB), not used. IOReport/HID bridge headers were adapted from third parties, so don't take them. |
| tanRdev/lucid-task-manager | MIT, © 2026 Tanvi Rahman | `ee0bf35bae95a85c7bd373d1c419b058a6f443fd` | Yes | Daemon map is a Swift literal (~406 entries). The README doesn't say where the list comes from. |
| sveinbjornt/sloth | BSD-3-Clause, © 2004-2026 Sveinbjorn Thordarson | `b3879bb790772e77927b7b363d0611fb504379bc` | Yes | Shells out to `/usr/sbin/lsof`, so its core can't be reused. |
| Sean10000/LaunchManager | MIT, © 2026 Shi-Cheng Ma | `edd75d922a54c10da0d638779471e93a1dece377` | Yes | Shells out to `launchctl` and `lsof` and elevates privileges through AppleScript. |
| timdreesen/simple-dev-server-viewer | MIT, © 2026 Simple Dev Server Viewer contributors | `b578c10c3a45895443a1dfea278462b5908d6c8e` | Yes | Tauri 2 app with a Rust backend (`src-tauri/src/lib.rs`) and a TS/React UI. |
| tnAnGel/Task-Manager-for-macOS ("Task Manager for macOS") | MIT, © 2026 Free Software | `f834762c03253532e43488caa7d46079bbf28653` | Yes, but it's JS/Electron | Used as a UX reference only. Its collectors shell out (`nettop`, `systeminformation`). |
| objective-see/TaskExplorer | **GPL-3.0** | `438c254e88b86a70c00a051828faafed21078bd4` | **No** | Study the approach only. It uses private `NetworkStatistics.framework` and `csops`. |
| xModern54/Task-Manager-MacOS *(extra, found during survey)* | **No license** (all rights reserved) | `f8462f6b54d71992473b421d5d43e273567d51af` | **No** | Architecture inspiration only: actor ProcessMonitor, startup providers, XPC helper. |

**Key finding:** most references collect data by shelling out to `ps`, `top`, `lsof`, `nettop`
or `launchctl`. SPEC §2 forbids that on the hot path, so actual code reuse is small.
It comes down to:
- the stats system-wide readers (CPU, memory, GPU, disk, network),
- data tables: lucid's daemon names and the dev-server rules,
- LaunchManager's plist handling and launchctl verb set (used for user actions, not polling).

Process-level collection is written from scratch on libproc.

## 2. Phase 1 — feature map

| # | Feature | Decision | Source (repo · file · symbol) / reason |
|---|---|---|---|
| 1.1 | Process enumeration: pid, ppid, uid, threads, start time, arch | **Write** | stats uses `/bin/ps` and `/usr/bin/top`. Ours uses `proc_listallpids`, `proc_pidinfo(PROC_PIDTASKALLINFO)` and `proc_pidpath`. Rosetta is detected with the `P_TRANSLATED` flag. |
| 1.2 | argv / env (`KERN_PROCARGS2` parser) | **Write** | No clean reusable implementation. Unit-tested against binary fixtures (SPEC §8). |
| 1.3 | Per-process CPU / memory / disk | **Write** | Deltas from `proc_pid_rusage(RUSAGE_INFO_V6)`. Memory is `ri_phys_footprint`. Disk is `ri_diskio_bytesread/written`, which stats `Modules/Disk/readers.swift` `ProcessReader` also uses. |
| 1.4 | Per-core CPU usage | **Adapt** · stats (MIT) | `Modules/CPU/readers.swift` · `LoadReader.read()` (~150 lines, `host_processor_info` tick deltas). Strip `Reader<T>`, `Store` and `NSLock`, then move it into an actor. |
| 1.5 | P/E core mapping | **Write** | stats walks the IORegistry (`e-core-count`). We use the public `sysctl hw.nperflevels` and `hw.perflevelN.{name,logicalcpu}` as the spec asks. |
| 1.6 | Memory composition + pressure | **Adapt** · stats (MIT) | `Modules/RAM/readers.swift` · `UsageReader` (~90 lines: `host_statistics64(HOST_VM_INFO64)`, `kern.memorystatus_vm_pressure_level`, `vm.swapusage`). Pressure transitions also come from `DispatchSource.makeMemoryPressureSource`. |
| 1.7 | GPU utilization | **Adapt (partial)** · stats (MIT) | `Modules/GPU/reader.swift` · `InfoReader.read()`. Take only the `IOAccelerator` → `PerformanceStatistics` part (`Device Utilization %`). The IOReport and SMC parts are **excluded** (private API). |
| 1.8 | Disk I/O | **Adapt** · stats (MIT) | `Modules/Disk/readers.swift` · `ActivityReader`, `driveStats`, `getDeviceIOParent` (DiskArbitration → IOBlockStorageDriver `Statistics`). |
| 1.9 | Network throughput | **Adapt** · stats (MIT) | `Modules/Net/readers.swift` · `getBytesInfo()` (~40 lines, `sysctl NET_RT_IFLIST2` / `if_msghdr2`). The nettop, CoreWLAN and public-IP code is excluded. |
| 1.10 | Energy column | **Write** | There is no public "Energy Impact" API. We build an approximate score from `rusage_info_v6` (`ri_billed_energy`, CPU time, wakeups), labelled as not identical to Activity Monitor. → D1 |
| 1.11 | Per-process Network and GPU columns | **Open** | No public API. stats and tnAnGel use `nettop`; TaskExplorer uses private `NetworkStatistics.framework`. → D2 |
| 1.12 | Apps / Background / System grouping | **Write** | `NSWorkspace.runningApplications`, injected into Core, plus uid and path rules. The grouping UX follows tnAnGel `src/renderer/js/views/processes.js` (idea only, no code). |
| 1.13 | Details tab columns, heat-map, column chooser | **Write** | UX follows tnAnGel `views/details.js` and `views/processes.js`. The table is our own `NSTableView` wrapper. |
| 1.14 | Code-signature status | **Write** | We take TaskExplorer's (GPL) approach only. Live processes use `SecCodeCopyGuestWithAttributes` (pid) and static checks use `SecStaticCodeCreateWithPath`; both feed `SecCodeCopySigningInformation`. Results are cached by path and mtime. |
| 1.15 | Actions (quit, force quit, suspend/resume, reveal, copy) | **Write** | `NSRunningApplication.terminate`, `kill(SIGKILL/SIGSTOP/SIGCONT)`. Trivial. |
| 1.16 | Critical-process protection | **Adapt (data)** · lucid (MIT) | `Lucid/Lucid/Services/ProcessDictionary.swift` entries with `.system` origin (`Models/ProcessOrigin.swift`) seed the protected list. It is extended with PID 0/1 and our own rules (launchd, kernel_task, WindowServer, loginwindow…). |
| 1.17 | Global hotkey + menu bar mini-graph | **Write** or SPM | The hotkey uses either Carbon `RegisterEventHotKey` or `sindresorhus/KeyboardShortcuts` (MIT, SPM; SPEC §3.6). → D3 |

## 3. Phase 2 — feature map

| # | Feature | Decision | Source / reason |
|---|---|---|---|
| 2.1 | Process tree with "tree lock" | **Write** | A ppid graph with stable ordering keyed by `ProcessID` (pid + start time). |
| 2.2 | Inspector: open files, sockets, pipes | **Write** | sloth runs `lsof -F` (`source/LsofTask.m`). We use `PROC_PIDLISTFDS`, then `PROC_PIDFDVNODEPATHINFO`, `PROC_PIDFDSOCKETINFO` and `PROC_PIDFDPIPEINFO`. Optional small adapt: sloth `source/util/IPUtils.m` (BSD-3) for address formatting. |
| 2.3 | Inspector: loaded dylibs | **Write** | Approach from TaskExplorer: loop `proc_pidinfo(PROC_PIDREGIONPATHINFO)` over regions. No `vmmap` (it suspends the target and needs entitlements). Limitation: dylibs from the shared cache are incomplete, and the UI documents this. |
| 2.4 | Inspector: environment, signature, notarization, entitlements | **Write** | Environment comes from the `KERN_PROCARGS2` parser. Entitlements come from `SecCodeCopySigningInformation(kSecCSRequirementInformation)`, **not** `csops`. Notarization is checked with a `SecRequirement` `notarized` check. |
| 2.5 | Network Ports tab (listening TCP/UDP → owner) | **Write** | LaunchManager runs `lsof -iTCP -sTCP:LISTEN`. We sweep socket fds per process with libproc. "Open in browser" is offered for localhost HTTP. |
| 2.6 | Dev-server detection | **Adapt (data)** · simple-dev-server-viewer (MIT) | `src-tauri/src/lib.rs` · `classify()`: 23 `(needle, framework, category, confidence)` rules plus port-range fallbacks. These become `Resources/dev-server-rules.json`, with docker, flask, django and uvicorn added. |
| 2.7 | Kill whole process tree | **Adapt (algorithm)** · simple-dev-server-viewer (MIT) | `lib.rs` · `collect_descendants()` does a BFS and kills children first. We add SIGTERM → grace period → SIGKILL escalation, an idea from LaunchManager `Services/ProcessKillService.swift` (MIT). |
| 2.8 | Startup tab: scan LaunchAgents/Daemons plists | **Adapt** · LaunchManager (MIT) | `LaunchManager/Services/PlistService.swift` (`scanAll`, `scanDirectory`, `parsePlist`), `Models/LaunchItem.swift`, `Models/InvalidPlist.swift`, `Services/DirectoryWatcher.swift`. |
| 2.9 | Startup enable/disable, Services restart | **Adapt (command set)** · LaunchManager (MIT) | `Services/LaunchctlService.swift` verbs: `bootstrap`, `bootout`, `enable`, `disable`, `kickstart`, `kill`, `print-disabled`. These are on-demand user actions, so running `launchctl` here is acceptable. System domain actions go through our helper, **not** AppleScript (`PrivilegeService.swift`). |
| 2.10 | Services tab: job list, status, PID | **Open** | There is no public launchd enumeration API. → D4 |
| 2.11 | Login Items (third-party) | **Write** | `SMAppService` only reports our own items. The BTM database (`sfltool dumpbtm`, needs root) is the only complete source. xModern54 parses it, but it has no license, so we use it as a reference only. → D4 |
| 2.12 | Plain-English daemon names | **Adapt (data)** · lucid (MIT) | `ProcessDictionary.swift` (~406 entries) is extracted to `Resources/daemon-names.json` with schema `{name, title, origin, source}`, so the community can edit it. |
| 2.13 | Privileged helper | **Write** | `SMAppService.daemon`, `NSXPCConnection` and `setCodeSigningRequirement` for client validation. xModern54's protocol surface is an idea only. |

## 4. Decisions (resolved 2026-10-08 by tech lead; see DECISIONS.md)

- **D1 — Energy column:** approximate score from `rusage_info_v6` (`ri_billed_energy` delta, CPU time, wakeups), tooltip "approximation, not identical to Activity Monitor".
- **D2 — Per-process Network / GPU:** both columns ship **hidden by default and marked "Phase 2"**. No `nettop` in Phase 1 (keeps SPEC §2 intact). In Phase 2, evaluate the IORegistry `AGXDeviceUserClient` `AppUsage` route for GPU (undocumented property, flagged) and an opt-in, off-hot-path network source.
- **D3 — Hotkey:** `sindresorhus/KeyboardShortcuts` via SPM (MIT). Added when the hotkey step starts, not in the skeleton.
- **D4 — Services list + third-party Login Items:** on-demand parsing of `launchctl print` / `print-disabled` and `sfltool dumpbtm` (the latter through the helper). Parsers get fixture-based unit tests. Never polled.

## 5. Reuse procedure (per SPEC §3)

For every adapted piece:
1. Keep the original copyright header and add `// Adapted from <owner>/<repo>@<sha>, <path>`.
2. Add the full license text to `THIRD_PARTY_NOTICES.md`.
3. Add a `DECISIONS.md` entry covering the repo, SHA, license, files and what changed.
4. Conform the code to the `Collector` protocol and Swift 6 concurrency, and give it tests with mocked sources.
