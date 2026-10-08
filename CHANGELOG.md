# Changelog

## 0.1.0

First release: Phases 1 to 3.

- Processes tab with Apps, Background and System groups, heat-mapped CPU, memory, energy, disk, network and GPU columns, search and Windows-style keys (Delete ends a task).
- Performance tab with live 60 s graphs for CPU (per core, P/E cores), memory composition and pressure, GPU, disk and network.
- Details tab with PID, parent, user, architecture, code signature and command line, a stable process tree view, and a per-process Inspector (open files, sockets, libraries, environment, entitlements).
- Network Ports tab listing every listening port with its owner, dev-server detection and one-click end of the whole server tree.
- Startup and Services tabs for login items and launchd agents and daemons, with enable, disable and restart.
- Optional privileged helper (signed builds) for root-owned processes and system launchd jobs.
- History tab (last hour, spikes, top processes at any moment) and threshold alerts with notifications.
- Menu bar CPU graph with a quick panel and a configurable global shortcut.
- Separate `proclens` command-line tool: ps, top, ports, kill, launchd and system with JSON and CSV output.
- No telemetry. The only network request is the opt-in update check.
