import SwiftUI
import ProcLensCore

/// Status + install/uninstall controls for the privileged helper. Used by Settings.
struct HelperSection: View {
    @Environment(AppModel.self) private var model
    @State private var helper = HelperStatusModel()

    var body: some View {
        Section("Helper") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(helper.statusTitle)
                }
            }
            Text("The helper lets ProcLens read stats of root-owned and other users' processes and manage system-wide launchd daemons.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !helper.isSignedBuild {
                Label("Available in signed builds", systemImage: "seal")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = helper.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Button("Install") { helper.install() }.disabled(!helper.canInstall)
                Button("Uninstall") { helper.uninstall() }.disabled(!helper.canUninstall)
                if helper.status == .requiresApproval {
                    Button("Open Login Items settings") { helper.openApprovalSettings() }
                }
                Spacer()
                Button { helper.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh status").accessibilityLabel("Refresh helper status")
            }
        }
        .onAppear {
            helper.onChange = { [services = model.services] in services.refreshHelperStatus() }
            helper.bind(model.services.helper)
        }
    }

    private var color: Color {
        switch helper.status {
        case .enabled: .green
        case .requiresApproval: .orange
        case .notRegistered, .notFound: .gray
        }
    }
}
