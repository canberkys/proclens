# proclens CLI

`proclens` is a dependency-free command-line tool built on `ProcLensCore` (no AppKit, hand-rolled argument parsing).

    swift build -c release --package-path ProcLensCore --product proclens
    ProcLensCore/.build/release/proclens --help

| Command | Description |
|---|---|
| `ps [--sort cpu\|mem\|pid\|name] [--limit N] [--json\|--csv]` | Process table from two samples 1 s apart (pid, name, user, cpu%, mem, threads, arch). |
| `top [--interval S] [--count N] [--limit N] [--json]` | Streams snapshots (default every 2 s, top 10 by CPU). `--json` prints one compact JSON object per line. |
| `ports [--json\|--csv]` | Listening TCP/UDP ports, owner and dev-server classification. |
| `kill <pid> [--force] [--tree] [--yes]` | SIGTERM (SIGKILL with `--force`); `--tree` ends descendants first. Prompts on a TTY unless `--yes`; without a TTY and without `--yes` it fails. |
| `launchd [--json]` | Launch agents/daemons with enabled/loaded/running state (table starts with a summary line). |
| `system [--json]` | CPU, memory, GPU, disk, network snapshot (rates need two samples, taken 1 s apart). |
| `--version`, `--help` | |

Options accept `--opt value` and `--opt=value`.

## Output
- Table: default, human-readable (memory in KB/MB/GB, binary units).
- `--json`: Codable structs with sorted keys, raw numbers (bytes, percent rounded to 0.1, bytes/s rounded to 0.01). Safe to diff and script.
- `--csv`: RFC 4180, header row, raw bytes.

## Exit codes
| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Error (no such process, signal failed, confirmation unavailable/declined, collection failure) |
| 2 | Usage error (unknown command/option, bad value) |
| 3 | Refused by `ProtectionPolicy` (PID 0/1, critical system processes, `proclens` itself) |

## Notes
- `kill --tree --force` sends SIGTERM and SIGKILL back to back (no grace period); `--tree` without `--force` waits 3 s before escalating.
- Single-process `kill` without `--force` sends SIGTERM only and reports if the process survived 3 s.
- Processes of other users or protected by the OS cannot be signalled (exit 1, `Operation not permitted`).
