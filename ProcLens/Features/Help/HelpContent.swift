import SwiftUI

/// One block of a help topic.
enum HelpBlock: Sendable {
    case paragraph(String)
    case bullets([String])
    /// (keys, action)
    case shortcuts([(String, String)])
}

struct HelpTopic: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    let summary: String
    let blocks: [HelpBlock]

    /// Lower-cased text used by search.
    var searchText: String {
        var parts = [title, summary]
        for b in blocks {
            switch b {
            case .paragraph(let t): parts.append(t)
            case .bullets(let t): parts += t
            case .shortcuts(let rows): parts += rows.flatMap { [$0.0, $0.1] }
            }
        }
        return parts.joined(separator: " ").lowercased()
    }
}

/// Keyboard shortcuts that are actually wired (menu bar, toolbar, tables, global hotkey).
enum ShortcutCatalog {
    static let rows: [(String, String)] = [
        ("⌘1 … ⌘7", "Processes, Performance, Details, Network Ports, Startup, Services, History"),
        ("Delete", "End task (selected rows in Processes, Details)"),
        ("⌥Delete", "Force Quit the selection"),
        ("⌘I", "Properties (Inspector) for the selection"),
        ("⌘K", "End process by PID…"),
        ("⌘R", "Refresh the Inspector"),
        ("⌘,", "Settings"),
        ("⌘?", "ProcLens Help"),
        ("⌃⌥⌘P", "Show ProcLens from anywhere (global shortcut, change it in Settings)"),
        ("⌘W · ⌘M · ⌘H · ⌘Q", "Close, Minimize, Hide, Quit"),
    ]
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(id: "start", title: "Getting started", symbol: "sparkles", color: .orange,
                  summary: "A tour of the window.",
                  blocks: [
                    .paragraph("ProcLens is a Task Manager for macOS. The sidebar switches between seven views; the toolbar and the Process menu act on whatever is selected."),
                    .bullets([
                        "Processes: apps, background and system processes with live CPU, memory, energy, disk, network and GPU.",
                        "Performance: 60-second graphs for CPU, memory, GPU, disk and network.",
                        "Details: one row per process with PID, user, architecture and signature, optionally as a tree.",
                        "Network Ports, Startup, Services and History cover listening ports, login items, launchd jobs and the last hour.",
                    ]),
                    .paragraph("Nothing is changed without asking. Ending a process always shows a confirmation first, and critical system processes are refused."),
                  ]),
        HelpTopic(id: "processes", title: "Processes and ending tasks", symbol: "list.bullet.rectangle", color: .blue,
                  summary: "Select, search, end, suspend.",
                  blocks: [
                    .paragraph("Rows are grouped into Apps, Background and System. Click a column header to sort; the search field matches name, PID and path."),
                    .bullets([
                        "End task (Delete) asks the process to quit politely. Force Quit (⌥Delete) kills it immediately.",
                        "End Process Tree also ends every child process, children first.",
                        "Suspend and Resume freeze and thaw a process without ending it.",
                        "Right-click a row, or use the Process menu, for Reveal in Finder, Copy PID and Copy Path.",
                        "⌘K ends a process by PID when you only know the number.",
                    ]),
                    .paragraph("PID 0 and 1, ProcLens itself and critical system processes cannot be ended. ProcLens tells you why."),
                  ]),
        HelpTopic(id: "performance", title: "Performance graphs", symbol: "chart.xyaxis.line", color: .green,
                  summary: "What each number means.",
                  blocks: [
                    .bullets([
                        "CPU: percentage of the whole machine. Per-core bars show each core, with performance and efficiency cores told apart. In process tables, 100% means one full core, so a busy process can exceed 100%.",
                        "Memory: the bar splits into app, wired, compressed and cached. Pressure (green, yellow, red) is a better health signal than how full the bar looks.",
                        "GPU, Disk, Network: utilisation and throughput. Network counts physical interfaces only.",
                    ]),
                    .paragraph("Graphs show the last 60 seconds at the sampling interval chosen in View > Update Speed or Settings."),
                    .paragraph("Alert rules on CPU use the same convention as the process tables: 100% is one core. System-wide CPU rules use the percentage of the whole machine."),
                  ]),
        HelpTopic(id: "details", title: "Details, tree and Inspector", symbol: "tablecells", color: .indigo,
                  summary: "Depth for one process.",
                  blocks: [
                    .paragraph("Details lists every process with PID, parent, user, architecture (arm64 or Intel under Rosetta), threads, path, command line, start time and code-signing status. Use the column chooser to show what you need."),
                    .bullets([
                        "Tree toggles a parent/child outline. Rows keep their place while values update; sort a column to reorder.",
                        "Double-click a row, or press ⌘I, to open the Inspector: open files, sockets, loaded libraries, environment, signature and entitlements.",
                        "The Inspector reads its data when it opens. Use Refresh (⌘R) to read it again.",
                    ]),
                  ]),
        HelpTopic(id: "ports", title: "Network Ports and dev servers", symbol: "network", color: .teal,
                  summary: "Who is listening, and kill it.",
                  blocks: [
                    .paragraph("Every listening TCP and UDP port with its owning process. Dev servers (node, vite, next, python, docker and similar) are recognised and grouped."),
                    .bullets([
                        "Open in Browser works for localhost HTTP servers.",
                        "End Process Tree… stops a dev server together with the workers it started, which frees the port.",
                        "Ports owned by system processes need the helper.",
                    ]),
                  ]),
        HelpTopic(id: "startup", title: "Startup and Services", symbol: "power", color: .pink,
                  summary: "Login items and launchd.",
                  blocks: [
                    .paragraph("Startup lists login items and launch agents and daemons from the user, system and Apple directories. Services shows launchd jobs with their state and PID."),
                    .bullets([
                        "Disable stops a job from starting at login or boot. A job that is running keeps running until it exits.",
                        "Items that are part of macOS are read-only.",
                        "A lock badge means changing the item needs the helper (system-wide jobs).",
                        "Reveal plist in Finder and Open plist show where an item is defined.",
                    ]),
                  ]),
        HelpTopic(id: "helper", title: "The helper", symbol: "lock.shield", color: .red,
                  summary: "Optional privileged component.",
                  blocks: [
                    .paragraph("Without the helper ProcLens works for your own processes. The helper is a small background service that lets it read stats of root-owned and other users' processes and manage system-wide launchd jobs, without asking for an admin password each time."),
                    .bullets([
                        "Open Settings and use Install in the Helper section. macOS asks you to approve it in System Settings > Login Items.",
                        "It is only available in signed, notarized builds. Debug and ad-hoc builds show \"Available in signed builds\".",
                        "Only ProcLens itself is allowed to talk to it, and Uninstall removes it again.",
                    ]),
                  ]),
        HelpTopic(id: "history", title: "History and alerts", symbol: "clock.arrow.circlepath", color: .purple,
                  summary: "What spiked, and when.",
                  blocks: [
                    .paragraph("History keeps the last hour in memory only: one second resolution for ten minutes, ten second buckets for the hour. Click or drag on the chart to see the top processes at that moment; red dots mark spikes above the thresholds. Nothing is written to disk and it starts empty at every launch."),
                    .paragraph("Alerts (button in History) send a notification when a rule holds long enough, for example any process above 80% CPU for 60 seconds, with a cooldown between repeats."),
                    .bullets([
                        "Per-process rules only fire while the window or menu bar panel is open.",
                        "Turn on Background monitoring in the Alerts window to evaluate them with the window hidden. It keeps the full sampler running, which uses noticeably more CPU.",
                    ]),
                  ]),
        HelpTopic(id: "menubar", title: "Menu bar panel", symbol: "menubar.rectangle", color: .cyan,
                  summary: "A glance without the window.",
                  blocks: [
                    .paragraph("The menu bar item draws a small CPU graph (with an optional percentage). Click it for a quick panel: live totals, the top processes (switch the metric, or search by name or PID), End Task on any row, the running dev servers, and buttons for Open ProcLens, Settings and Quit."),
                    .bullets([
                        "Settings controls the percentage, the Dock icon and the global shortcut (⌃⌥⌘P by default).",
                        "With the Dock icon off ProcLens lives only in the menu bar.",
                    ]),
                  ]),
        HelpTopic(id: "cli", title: "Command-line tool", symbol: "terminal", color: .gray,
                  summary: "proclens for scripts.",
                  blocks: [
                    .paragraph("proclens is a separate, dependency-free command-line tool (installed apart from the app, for example with Homebrew). It uses the same collectors, so its numbers match the app."),
                    .bullets([
                        "proclens ps [--sort cpu|mem|pid|name] [--limit N] [--json|--csv]",
                        "proclens top [--interval S] [--count N] [--json]",
                        "proclens ports, launchd and system, each with --json",
                        "proclens kill <pid> [--force] [--tree] [--yes]",
                        "Exit codes: 0 ok, 1 error, 2 usage, 3 refused for a protected process.",
                    ]),
                    .paragraph("Run proclens --help for everything."),
                  ]),
        HelpTopic(id: "privacy", title: "Privacy", symbol: "hand.raised", color: .mint,
                  summary: "No telemetry, ever.",
                  blocks: [
                    .paragraph("ProcLens collects nothing and sends nothing. History and alert state stay on your Mac, and history is not even saved."),
                    .paragraph("The one exception is the update check. It is a single request to the GitHub releases page of the project. It runs when you choose Check for Updates… and automatically at most once a day; you can turn the automatic check off in Settings → Updates. It sends no identifiers beyond the app name and version in the request header."),
                  ]),
        HelpTopic(id: "shortcuts", title: "Keyboard shortcuts", symbol: "keyboard", color: .brown,
                  summary: "Everything you can do without the mouse.",
                  blocks: [
                    .shortcuts(ShortcutCatalog.rows),
                    .paragraph("Arrow keys move the selection in tables, Return opens or expands the selected row, and Tab moves between controls."),
                  ]),
    ]
}
