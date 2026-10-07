import Darwin
import ProcLensCLIKit

// Let `proclens ps | head` end quietly instead of dying with an uncaught write error.
signal(SIGPIPE, SIG_DFL)
exit(await CLIMain.run(arguments: Array(CommandLine.arguments.dropFirst())))
