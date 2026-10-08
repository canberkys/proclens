<div align="center">
  <img src="docs/assets/proclens-icon.png" width="128" alt="ProcLens icon" />
  <h1>ProcLens</h1>
  <p><strong>A native, sysadmin-grade Task Manager for macOS.</strong></p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Swift-6-FA7343?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/github/v/release/canberkys/proclens?style=flat-square&label=release" alt="Latest release">
    <img src="https://img.shields.io/badge/license-GPLv3-blue?style=flat-square" alt="License: GPLv3">
  </p>
</div>

---

ProcLens puts the Windows 11 Task Manager layout, Process Explorer depth and a
launchd manager into one small native Mac app. It is meant for power users,
sysadmins and developers who otherwise reach for `top`, `lsof`, `launchctl`
and `ps`.

It collects everything through native APIs (libproc, sysctl, Mach host
statistics, IOKit, Security.framework). It never shells out to `ps`, `top` or
`lsof`, and it stays light: about 0.5% CPU in the background at 1 s sampling
with 1,000+ processes, and a ~10 MB universal bundle.

**Status:** early development, Phases 1–3 of the [spec](docs/SPEC.md) are
implemented. The first signed and notarized release is in preparation.

## Features

| | |
|---|---|
| **Processes** | Apps / Background / System groups, helpers under their app, CPU, memory, energy and disk columns with heat-map coloring, search by name, PID or path |
| **Ending tasks** | Windows-style: right-click → End task, Delete key, Force quit, Suspend/Resume, End process tree, End process by PID (⌘K). Critical system processes are refused, and every destructive action is confirmed |
| **Performance** | CPU per core with Performance/Efficiency cores marked, memory composition and pressure, GPU, disk and network, 60 s graphs |
| **Details & Inspector** | PID, PPID, user, architecture (Rosetta), threads, command line, start time, code signature; process tree; Inspector with open files and sockets, loaded images, environment, entitlements and notarization |
| **Network Ports** | Every listening TCP/UDP port and its process, with dev-server detection (Vite, Next.js, Python, Postgres and more), Open in browser and kill the whole tree |
| **Startup & Services** | LaunchAgents, LaunchDaemons and login items grouped by signer; enable/disable, start, restart, stop |
| **History & alerts** | One hour of history with "what spiked at 14:32?"; threshold rules with notifications |
| **Menu bar** | CPU at a glance; a quick panel with gauges, search, top processes and running dev servers |
| **`proclens` CLI** | `ps`, `top`, `ports`, `kill [--tree]`, `launchd`, `system` with JSON/CSV output — see [docs/CLI.md](docs/CLI.md) |
| **Privileged helper** | Optional (`SMAppService`), for root-owned processes and system-domain launchd jobs; strict code-signature check on every connection |

## Privacy

No telemetry. The only network request is the update check: Sparkle reads the
appcast hosted in this repository at most once a day (can be turned off in
Settings). Updates are EdDSA-signed and notarized.

## Building from source

Requirements: macOS 14+, Xcode 16+ (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project ProcLens.xcodeproj -scheme ProcLens -configuration Release build
swift test --package-path ProcLensCore
```

The app is not sandboxed (the App Sandbox blocks process enumeration), so it is
distributed outside the Mac App Store as a signed, notarized DMG. Release steps
are in [docs/RELEASING.md](docs/RELEASING.md).

## Acknowledgements

ProcLens adapts code and data from MIT/BSD-licensed projects, notably
[exelban/stats](https://github.com/exelban/stats),
[Sean10000/LaunchManager](https://github.com/Sean10000/LaunchManager),
[tanRdev/lucid-task-manager](https://github.com/tanRdev/lucid-task-manager) and
[timdreesen/simple-dev-server-viewer](https://github.com/timdreesen/simple-dev-server-viewer).
Details and license texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
and the reasoning for each reuse is in [docs/REUSE_PLAN.md](docs/REUSE_PLAN.md).

## License

GNU General Public License v3.0 with additional terms under Section 7 (no
misrepresentation of origin, modified versions must be renamed, no trademark
grant for the ProcLens name or icon). See [LICENSE](LICENSE).
