import SwiftUI

struct HistoryView: View {
    var body: some View {
        ContentUnavailableView("History", systemImage: "clock.arrow.circlepath",
                               description: Text("The last hour of CPU, memory, disk and network, and what spiked when."))
    }
}
