import ProcLensCore
import SwiftUI

extension AlertRule {
    var targetDescription: String {
        switch target {
        case .anyProcess: "Any process"
        case .systemTotal: "System total"
        case .process(let name, let match): match == .exact ? "Process \"\(name)\"" : "Process containing \"\(name)\""
        }
    }

    var metricDescription: String {
        switch metric {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .energy: "Energy"
        }
    }

    var thresholdDescription: String {
        switch metric {
        // Per-process CPU is measured per core (100% = one full core, like top/Activity Monitor);
        // the system total is a share of the whole machine.
        case .cpu: target == .systemTotal ? "\(Int(threshold.rounded()))%" : "\(Int(threshold.rounded()))% of a core"
        case .memory: "\(Int(threshold.rounded())) MB"
        case .energy: "\(Int(threshold.rounded()))"
        }
    }

    /// "Any process › CPU ≥ 80% for 60 s"
    var summary: String {
        "\(targetDescription) › \(metricDescription) ≥ \(thresholdDescription) for \(Int(durationSeconds.rounded())) s"
    }

    var isPerProcess: Bool {
        if case .systemTotal = target { return false }
        return true
    }
}

/// Rules editor presented as a sheet from the History toolbar.
struct AlertRulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AlertRule] = []
    @State private var loaded = false
    @State private var editing: AlertRule?
    @State private var isNew = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Alerts").font(.title2.bold())
                Spacer()
                Button { startAdd() } label: { Label("Add Rule", systemImage: "plus") }
            }

            if rules.isEmpty {
                ContentUnavailableView("No rules", systemImage: "bell.slash",
                                       description: Text("Add a rule such as \"Any process › CPU ≥ 80% for 60 s\"."))
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                List {
                    ForEach($rules) { $rule in
                        HStack {
                            Toggle("", isOn: $rule.isEnabled)
                                .labelsHidden()
                                .accessibilityLabel("Enable \(rule.summary)")
                                .onChange(of: rule.isEnabled) { persist() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.summary).foregroundStyle(rule.isEnabled ? .primary : .secondary)
                                Text("Cooldown \(Int(rule.cooldownSeconds.rounded())) s").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { editing = rule; isNew = false } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Edit").accessibilityLabel("Edit rule")
                            Button(role: .destructive) { delete(rule) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete").accessibilityLabel("Delete rule")
                        }
                    }
                }
                .frame(minHeight: 160)
            }

            Divider()
            Toggle(isOn: Binding(get: { model.backgroundMonitoring }, set: { model.setBackgroundMonitoring($0) })) {
                Text("Background monitoring (needed for per-process alerts while the window is hidden; uses more CPU)")
            }
            if !model.backgroundMonitoring, rules.contains(where: { $0.isEnabled && $0.isPerProcess }) {
                Label("Per-process rules only fire while the ProcLens window or menu bar panel is open. Turn on Background monitoring to watch processes while the window is hidden.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            guard !loaded else { return }
            rules = await model.services.alerts.currentRules()
            loaded = true
        }
        .sheet(item: $editing) { rule in
            AlertRuleForm(rule: rule, isNew: isNew) { saved in
                if let i = rules.firstIndex(where: { $0.id == saved.id }) { rules[i] = saved } else { rules.append(saved) }
                persist()
            }
        }
    }

    private func startAdd() {
        isNew = true
        editing = AlertRule(name: "", target: .anyProcess, metric: .cpu, threshold: 80, durationSeconds: 60)
    }

    private func delete(_ rule: AlertRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    private func persist() {
        guard loaded else { return }
        for i in rules.indices { rules[i].name = rules[i].summary }
        do {
            try model.services.saveAlertRules(rules)
            saveError = nil
            AlertNotifier.shared.rulesChanged(rules)
        } catch {
            saveError = "Could not save rules: \(error.localizedDescription)"
        }
    }
}

private struct AlertRuleForm: View {
    enum TargetKind: String, CaseIterable, Identifiable {
        case system = "System total", any = "Any process", nameContains = "Process name contains", nameEquals = "Process name equals"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    let onSave: (AlertRule) -> Void
    @State private var rule: AlertRule
    @State private var kind: TargetKind
    @State private var processName: String

    init(rule: AlertRule, isNew: Bool, onSave: @escaping (AlertRule) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _rule = State(initialValue: rule)
        switch rule.target {
        case .systemTotal: _kind = State(initialValue: .system); _processName = State(initialValue: "")
        case .anyProcess: _kind = State(initialValue: .any); _processName = State(initialValue: "")
        case .process(let n, let m):
            _kind = State(initialValue: m == .exact ? .nameEquals : .nameContains); _processName = State(initialValue: n)
        }
    }

    private var unit: String {
        switch rule.metric {
        case .cpu: rule.target == .systemTotal ? "% of all cores" : "% (100 = one core)"
        case .memory: "MB"
        case .energy: "score"
        }
    }

    private var isValid: Bool {
        rule.threshold > 0 && rule.durationSeconds >= 1 && rule.cooldownSeconds >= 0
            && (kind == .system || kind == .any || !processName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Rule" : "Edit Rule").font(.title3.bold())
            Form {
                Picker("Target", selection: $kind) {
                    ForEach(TargetKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if kind == .nameContains || kind == .nameEquals {
                    TextField("Process name", text: $processName)
                }
                Picker("Metric", selection: $rule.metric) {
                    Text("CPU").tag(AlertRule.Metric.cpu)
                    Text("Memory").tag(AlertRule.Metric.memory)
                    Text("Energy").tag(AlertRule.Metric.energy)
                }
                LabeledContent("At or above") {
                    HStack {
                        TextField("", value: $rule.threshold, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                        Text(unit).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("For at least") {
                    HStack {
                        TextField("", value: $rule.durationSeconds, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Cooldown") {
                    HStack {
                        TextField("", value: $rule.cooldownSeconds, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                        Text("seconds between alerts").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    let name = processName.trimmingCharacters(in: .whitespaces)
                    switch kind {
                    case .system: rule.target = .systemTotal
                    case .any: rule.target = .anyProcess
                    case .nameContains: rule.target = .process(name: name, match: .contains)
                    case .nameEquals: rule.target = .process(name: name, match: .exact)
                    }
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
