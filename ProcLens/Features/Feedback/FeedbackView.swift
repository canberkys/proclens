import AppKit
import Darwin
import ProcLensCore
import SwiftUI

/// Help → Report an Issue…: a small form that sends a bug report or feature request through the relay Worker.
/// Sends only when the user presses Send, and shows exactly which diagnostics would be attached.
struct FeedbackView: View {
    @Environment(AppModel.self) private var model

    @State private var kind: FeedbackClient.Kind = .bug
    @State private var title = ""
    @State private var details = ""
    @State private var attach = true
    @State private var showDiagnostics = false
    @State private var state: SendState = .idle

    init() {}

    #if DEBUG
    init(previewTitle: String, previewDetails: String, expanded: Bool) {
        _title = State(initialValue: previewTitle)
        _details = State(initialValue: previewDetails)
        _showDiagnostics = State(initialValue: expanded)
    }
    #endif

    private enum SendState: Equatable {
        case idle, sending
        case sent(Int?, URL?)
        case failed(String)
    }

    private var diagnostics: String { FeedbackDiagnostics.text(interval: model.interval, helper: model.services.helper.registrationStatus()) }
    private var ready: Bool { !title.trimmed.isEmpty && !details.trimmed.isEmpty }
    private var sending: Bool { state == .sending }

    var body: some View {
        Group {
            if case .sent(let number, let url) = state {
                sentView(number: number, url: url)
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 480)
        .frame(minHeight: 460)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Report an Issue").font(.title2.bold())
            Picker("Type", selection: $kind) {
                ForEach(FeedbackClient.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            TextField("Title", text: $title).textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $details)
                    .font(.body)
                    .frame(height: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Attach diagnostics", isOn: $attach)
                DisclosureGroup("Diagnostics that will be attached", isExpanded: $showDiagnostics) {
                    Text(attach ? diagnostics : "Nothing will be attached.")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.callout)
                Text("Never included: process names, paths, your user or Mac name, IP addresses.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(sending)

            if case .failed(let message) = state {
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    if let url = FeedbackClient.browserFallbackURL(title: title.trimmed, body: browserBody) {
                        Button("Open a GitHub issue in the browser") { NSWorkspace.shared.open(url) }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    if sending { ProgressView().controlSize(.small) } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || sending)
                .accessibilityLabel(sending ? "Sending" : "Send")
            }
        }
    }

    private func sentView(number: Int?, url: URL?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text(number.map { "Thanks! Issue #\($0) created" } ?? "Thanks! Issue created").font(.title2.bold())
            if let url { Link("Open on GitHub", destination: url) }
            Button("Done") { reset() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browserBody: String {
        attach ? "\(details.trimmed)\n\n---\nDiagnostics:\n\(diagnostics)" : details.trimmed
    }

    private func reset() {
        title = ""; details = ""; state = .idle
    }

    private func submit() async {
        state = .sending
        do {
            let created = try await FeedbackClient().send(kind: kind, title: title, description: details,
                                                          diagnostics: attach ? diagnostics : nil)
            state = .sent(created.number, created.url)
        } catch let failure as FeedbackClient.Failure {
            state = .failed(failure.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The only data a report can carry. Deliberately a closed list: nothing from the process table, no paths,
/// user name, host name or addresses.
enum FeedbackDiagnostics {
    static func text(interval: SamplingInterval, helper: HelperRegistrationStatus) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let arch = "arm64 (Apple Silicon)"
        #else
        let arch = "x86_64 (Intel)"
        #endif
        let helperText: String = switch helper {
        case .enabled: "installed"
        case .requiresApproval: "needs approval"
        case .notRegistered, .notFound: "not installed"
        }
        return [
            "ProcLens \(version) (build \(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac model: \(sysctlString("hw.model") ?? "unknown")",
            "CPU architecture: \(arch)",
            "Helper: \(helperText)",
            "Sampling interval: \(interval.rawValue.formatted()) s",
            "Menu bar style: \(MenuBarStyle.stored.rawValue)",
        ].joined(separator: "\n")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
