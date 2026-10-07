import SwiftUI

/// Zero-size view that runs `action` whenever the visible snapshot ticks. Keeping the per-tick observation in this tiny
/// view means the parent's body is not re-evaluated every second.
struct TickDriver: View {
    let model: AppModel
    let action: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.visibleSnapshot?.instant, initial: true) { action() }
            .accessibilityHidden(true)
    }
}
