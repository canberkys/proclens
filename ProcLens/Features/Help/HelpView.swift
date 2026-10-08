import SwiftUI

/// Tips-style help: searchable topic list on the left, article on the right.
struct HelpView: View {
    @State private var query = ""
    @State private var selection: String? = HelpContent.topics.first?.id
    @AppStorage(HelpNavigation.topicKey) private var pendingTopic = ""
    @Environment(\.openWindow) private var openWindow

    private var topics: [HelpTopic] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpContent.topics }
        return HelpContent.topics.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
                .background(.background.secondary)
            Divider()
            detail
        }
        .onChange(of: query) { _, _ in
            if let first = topics.first, !topics.contains(where: { $0.id == selection }) { selection = first.id }
        }
        .onAppear(perform: consumePending)
        .onChange(of: pendingTopic) { _, _ in consumePending() }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search help", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 12).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(topics) { topic in
                        Button { selection = topic.id } label: {
                            HStack(spacing: 10) {
                                Badge(symbol: topic.symbol, color: topic.color, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(topic.title).lineLimit(1)
                                    Text(topic.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8)
                            .contentShape(Rectangle())
                            .background(selection == topic.id ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == topic.id ? .isSelected : [])
                    }
                }
                .padding(8)
            }
            .overlay {
                if topics.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            Divider()
            Button { openWindow(id: "feedback") } label: {
                Label("Report an Issue…", systemImage: "exclamationmark.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var detail: some View {
        if let topic = HelpContent.topics.first(where: { $0.id == selection }), topics.contains(where: { $0.id == topic.id }) {
            TopicDetail(topic: topic)
        } else {
            ContentUnavailableView("Choose a topic", systemImage: "questionmark.circle")
        }
    }

    private func consumePending() {
        guard !pendingTopic.isEmpty else { return }
        query = ""
        selection = pendingTopic
        pendingTopic = ""
    }
}

struct Badge: View {
    let symbol: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

private struct TopicDetail: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Badge(symbol: topic.symbol, color: topic.color, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title).font(.title.bold())
                        Text(topic.summary).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let t):
                        Text(t).fixedSize(horizontal: false, vertical: true)
                    case .bullets(let items):
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(topic.color)
                                    Text(item).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    case .shortcuts(let rows):
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            ForEach(rows, id: \.0) { row in
                                GridRow {
                                    Text(row.0).font(.body.monospaced()).gridColumnAlignment(.leading)
                                    Text(row.1).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

/// Renders the bundled CHANGELOG.md (simple headings and bullets) in its own window.
struct ReleaseNotesView: View {
    static func load() -> String {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "# Changelog\n\nThe release notes are not available in this build."
    }

    var text: String = Self.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                    line(String(raw))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder private func line(_ l: String) -> some View {
        if l.hasPrefix("# ") {
            Text(l.dropFirst(2)).font(.largeTitle.bold())
        } else if l.hasPrefix("## ") {
            Text(l.dropFirst(3)).font(.title2.bold()).padding(.top, 8)
        } else if l.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(l.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
            }
        } else if !l.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(inline(l)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
