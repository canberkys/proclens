import SwiftUI

struct ProcessesView: View {
    var body: some View {
        ContentUnavailableView("Processes", systemImage: "list.bullet.rectangle", description: Text("Apps, background and system processes with CPU, memory, disk and network columns."))
    }
}
