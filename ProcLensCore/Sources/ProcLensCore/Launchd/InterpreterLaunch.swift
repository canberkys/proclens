import Foundation

/// A launchd job whose program is a script interpreter (`/bin/sh script.sh`, `/usr/bin/env node app.js`,
/// `/usr/bin/open -a App`). The interpreter says nothing about who owns the job; the script does.
public struct InterpreterLaunch: Sendable, Hashable {
    /// Interpreter binary name, e.g. `bash`, `python3`, `env`, `open`.
    public var interpreter: String
    /// Script path (or app name for `open -a`); nil for inline commands (`-c`, `-e`).
    public var target: String?
    public var isInline: Bool

    static let names: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "env",
                                     "node", "nodejs", "ruby", "perl", "osascript", "open", "php", "deno", "bun"]

    static func isInterpreter(_ basename: String) -> Bool {
        names.contains(basename) || basename.hasPrefix("python")
    }

    /// Shell-like flags that take a value we should skip.
    private static let valueFlags: Set<String> = ["-o", "-O", "--rcfile", "--init-file", "-r", "--require", "-I", "-W"]

    /// Parses an argv; nil when `arguments[0]` is not a known interpreter.
    public static func parse(_ arguments: [String]) -> InterpreterLaunch? {
        guard let first = arguments.first else { return nil }
        let name = (first as NSString).lastPathComponent
        guard isInterpreter(name) else { return nil }
        var rest = Array(arguments.dropFirst())
        var interpreter = name

        if name == "env" {
            // Skip env flags and VAR=value assignments; the next token is the real interpreter or program.
            while let next = rest.first, next.hasPrefix("-") || next.contains("=") { rest.removeFirst() }
            guard let real = rest.first else { return InterpreterLaunch(interpreter: name, target: nil, isInline: false) }
            rest.removeFirst()
            interpreter = (real as NSString).lastPathComponent
            if !isInterpreter(interpreter) {
                // `env FOO=1 /path/to/tool args`: the tool itself is the target.
                return InterpreterLaunch(interpreter: name, target: real, isInline: false)
            }
        }

        if interpreter == "open" {
            var index = 0
            while index < rest.count {
                let arg = rest[index]
                if arg == "-a" || arg == "-b", index + 1 < rest.count {
                    return InterpreterLaunch(interpreter: interpreter, target: rest[index + 1], isInline: false)
                }
                if !arg.hasPrefix("-") { return InterpreterLaunch(interpreter: interpreter, target: arg, isInline: false) }
                index += 1
            }
            return InterpreterLaunch(interpreter: interpreter, target: nil, isInline: false)
        }

        var index = 0
        while index < rest.count {
            let arg = rest[index]
            if arg == "-c" || arg == "-e" || arg == "-E" || arg == "--eval" || arg == "-r" && interpreter == "php" {
                return InterpreterLaunch(interpreter: interpreter, target: nil, isInline: true)
            }
            if arg == "-m", index + 1 < rest.count {
                return InterpreterLaunch(interpreter: interpreter, target: rest[index + 1], isInline: false)
            }
            if valueFlags.contains(arg) { index += 2; continue }
            if arg.hasPrefix("-") && arg != "-" { index += 1; continue }
            return InterpreterLaunch(interpreter: interpreter, target: arg, isInline: false)
        }
        return InterpreterLaunch(interpreter: interpreter, target: nil, isInline: false)
    }
}

extension LaunchdItem {
    /// Non-nil when the job runs through a script interpreter.
    public var interpreterLaunch: InterpreterLaunch? {
        if !programArguments.isEmpty { return InterpreterLaunch.parse(programArguments) }
        return InterpreterLaunch.parse([program])
    }

    public var isInterpreterLaunch: Bool { interpreterLaunch != nil }

    /// What the job actually runs: the script (or app) for interpreter launches, else `program`.
    /// "inline command" when the interpreter is given code via `-c`/`-e`.
    public var effectiveProgram: String {
        guard let launch = interpreterLaunch else { return program }
        if launch.isInline { return "inline command" }
        return launch.target ?? program
    }

    /// Path that should be code-signature checked; nil for script launches (scripts are never signed).
    public var signablePath: String? {
        if isInterpreterLaunch { return nil }
        return program.hasPrefix("/") ? program : nil
    }
}
