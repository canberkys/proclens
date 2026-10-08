import Foundation
import ProcLensCore

/// Actions a process table can request. Execution and confirmation live in `ProcessActionCenter`.
enum ProcessAction: String, CaseIterable, Sendable {
    case quit, forceQuit, endTree, suspend, resume, properties, revealInFinder, copyPath, copyPID

    var title: String {
        switch self {
        case .quit: "End task"
        case .forceQuit: "Force quit"
        case .endTree: "End process tree"
        case .suspend: "Suspend"
        case .resume: "Resume"
        case .properties: "Properties…"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy path"
        case .copyPID: "Copy PID"
        }
    }

    /// Context-menu layout, Windows order; `nil` is a separator.
    static let menuLayout: [ProcessAction?] = [
        .quit, .forceQuit, .endTree, nil, .suspend, .resume, nil, .properties, nil, .revealInFinder, .copyPID, .copyPath,
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
    private let opensInspector: Bool
    /// `opensInspector`: double-click / Return on a process row opens its inspector (Details).
    init(_ center: ProcessActionCenter, opensInspector: Bool = false) {
        self.center = center
        self.opensInspector = opensInspector
    }

    func perform(_ action: ProcessAction, on ids: [ProcessID]) { center.request(action, on: ids) }
    func open(_ ids: [ProcessID]) { if opensInspector { center.request(.properties, on: ids) } }
    func deletePressed(on ids: [ProcessID]) { center.request(.quit, on: ids) }
}
