import SwiftUI

struct PerformanceView: View {
    var body: some View {
        ContentUnavailableView("Performance", systemImage: "chart.xyaxis.line", description: Text("Live CPU, memory, GPU, disk and network graphs."))
    }
}
