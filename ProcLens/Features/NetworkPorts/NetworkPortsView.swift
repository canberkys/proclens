import SwiftUI

struct NetworkPortsView: View {
    var body: some View {
        ContentUnavailableView("Network Ports", systemImage: "network", description: Text("Listening TCP/UDP ports mapped to their owning processes (Phase 2)."))
    }
}
