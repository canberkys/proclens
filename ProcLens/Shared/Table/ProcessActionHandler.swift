import Foundation
import OSLog
import ProcLensCore

/// Actions a process table can request. Implementations arrive in a later step (SPEC §5 item 4).
enum ProcessAction: String, CaseIterable, Sendable {
    case quit, forceQuit, suspend, resume, revealInFinder, copyPath, copyPID

    var title: String {
        switch self {
        case .quit: "End Task"
        case .forceQuit: "Force Quit"
        case .suspend: "Suspend"
        case .resume: "Resume"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        case .copyPID: "Copy PID"
        }
    }
}

/// Receives user intent from the process tables. Tables never act on processes themselves.
@MainActor
protocol ProcessActionHandler: AnyObject {
    /// A context-menu item was chosen.
    func perform(_ action: ProcessAction, on ids: [ProcessID])
    /// Double-click or Return on process rows.
    func open(_ ids: [ProcessID])
    /// Delete / Forward-Delete pressed with a selection.
    func deletePressed(on ids: [ProcessID])
}

extension ProcessActionHandler {
    func perform(_ action: ProcessAction, on ids: [ProcessID]) {
        ProcessActionLog.logger.info("action \(action.rawValue, privacy: .public) on \(ids.count) process(es) (not implemented)")
    }
    func open(_ ids: [ProcessID]) {
        ProcessActionLog.logger.info("open \(ids.count) process(es) (not implemented)")
    }
    func deletePressed(on ids: [ProcessID]) {
        ProcessActionLog.logger.info("delete key on \(ids.count) process(es) (not implemented)")
    }
}

enum ProcessActionLog {
    static let logger = Logger(subsystem: "com.canberkki.ProcLens", category: "actions")
}

/// Default handler: logs only.
final class LoggingProcessActionHandler: ProcessActionHandler {
    init() {}
}
