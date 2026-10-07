import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case performance = "Performance"
    case details = "Details"
    case networkPorts = "Network Ports"
    case startup = "Startup"
    case services = "Services"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .processes: "list.bullet.rectangle"
        case .performance: "chart.xyaxis.line"
        case .details: "tablecells"
        case .networkPorts: "network"
        case .startup: "power"
        case .services: "gearshape.2"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .processes, .performance, .details: true
        case .networkPorts, .startup, .services: false
        }
    }
}

struct ContentView: View {
    #if DEBUG
    @State private var selection: SidebarItem? = DebugSnapshot.initialTab ?? .processes
    #else
    @State private var selection: SidebarItem? = .processes
    #endif

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    HStack {
                        Label(item.rawValue, systemImage: item.symbol)
                        if !item.isAvailable {
                            Spacer()
                            Text("Phase 2")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!item.isAvailable)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch selection ?? .processes {
            case .processes: ProcessesView()
            case .performance: PerformanceView()
            case .details: DetailsView()
            case .networkPorts: NetworkPortsView()
            case .startup: StartupView()
            case .services: ServicesView()
            }
        }
    }
}
