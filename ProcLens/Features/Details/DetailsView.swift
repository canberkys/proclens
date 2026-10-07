import SwiftUI

struct DetailsView: View {
    var body: some View {
        ContentUnavailableView("Details", systemImage: "tablecells", description: Text("Per-process details: PID, user, architecture, path and code-sign status."))
    }
}
