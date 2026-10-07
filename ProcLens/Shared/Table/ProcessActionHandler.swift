import Foundation
import ProcLensCore

/// Actions a process table can request. Execution and confirmation live in `ProcessActionCenter`.
enum ProcessAction: String, CaseIterable, Sendable {
    case quit, forceQuit, suspend, resume, revealInFinder, copyPath, copyPID

    var title: String {
        switch self {
        case .quit: "End task"
        case .forceQuit: "Force quit"
        case .suspend: "Suspend"
        case .resume: "Resume"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy path"
        case .copyPID: "Copy PID"
        }
    }

    /// Context-menu layout, Windows order; `nil` is a separator.
    static let menuLayout: [ProcessAction?] = [
        .quit, .forceQuit, nil, .suspend, .resume, nil, .revealInFinder, .copyPID, .copyPath,
    ]
}

/// Receives user intent from the process tables. Tables never act on processes themselves.
@MainActor
protocol ProcessActionHandler: AnyObject {
    /// A context-menu item was chosen.
    func perform(_ action: ProcessAction, on ids: [ProcessID])
    /// Return on process rows that cannot expand (double-click / Return on groups and apps toggle expansion in the table).
    func open(_ ids: [ProcessID])
    /// Delete / Forward-Delete pressed with a selection: End task.
    func deletePressed(on ids: [ProcessID])
}

/// Forwards table intent to the shared `ProcessActionCenter` (validation, confirmation, execution).
@MainActor
final class CenterActionHandler: ProcessActionHandler {
    private let center: ProcessActionCenter
    init(_ center: ProcessActionCenter) { self.center = center }

    func perform(_ action: ProcessAction, on ids: [ProcessID]) { center.request(action, on: ids) }
    func open(_ ids: [ProcessID]) {}
    func deletePressed(on ids: [ProcessID]) { center.request(.quit, on: ids) }
}
