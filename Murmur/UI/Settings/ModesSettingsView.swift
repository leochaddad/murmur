import SwiftUI

struct ModesSettingsView: View {
    @Environment(ModeStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(ModelCatalog.self) private var catalog
    @State private var selection: UUID? = Mode.defaultID
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ModeRow(mode: store.modes[0], isActive: activeID == Mode.defaultID)
                        .tag(Mode.defaultID)
                    ForEach(store.customModes) { mode in
                        ModeRow(mode: mode, isActive: activeID == mode.id)
                            .tag(mode.id)
                    }
                    .onMove { store.moveCustomModes(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))

                HStack(spacing: 0) {
                    Button {
                        let model = catalog.textModels.contains(ModelCatalog.recommendedTextModel)
                            ? ModelCatalog.recommendedTextModel : (catalog.textModels.first ?? ModelCatalog.recommendedTextModel)
                        selection = store.add(model: model).id
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add a Mode")
                    Divider().frame(height: 16)
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil || selection == Mode.defaultID)
                    .help("Delete the selected Mode")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(width: 200)
            .padding([.leading, .vertical], 16)

            Group {
                if let id = selection, store.mode(withID: id) != nil {
                    ModeEditor(mode: binding(for: id), isActive: activeID == id) {
                        preferences.activeModeID = id
                    }
                    .id(id)
                } else {
                    Text("Select a Mode")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 560)
        .confirmationDialog(
            "Delete “\(store.mode(withID: selection)?.name ?? "")”?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                if let id = selection {
                    store.delete(id)
                    selection = Mode.defaultID
                }
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var activeID: UUID { store.resolve(preferences.activeModeID).id }

    private func binding(for id: UUID) -> Binding<Mode> {
        Binding(
            get: { store.mode(withID: id) ?? .default },
            set: { store.update($0) }
        )
    }
}

private struct ModeRow: View {
    let mode: Mode
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: mode.isDefault ? "text.cursor" : "wand.and.stars")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(mode.name.isEmpty ? "Untitled" : mode.name)
                .lineLimit(1)
                .foregroundStyle(mode.isDefault || mode.isEnabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .help("Active Mode")
            }
        }
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    let isActive: Bool
    let makeActive: () -> Void

    @Environment(ModelCatalog.self) private var catalog
    @Environment(ModeStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(APIKeyStore.self) private var apiKeys

    @State private var sample = ""
    @State private var testOutput: String?
    @State private var testError: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            if mode.isDefault {
                Section {
                    Text("Inserts exactly what you said, with no extra processing. The fastest option, and it can’t be deleted.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    activeRow
                } header: {
                    Text("Default")
                }
            } else {
                Section {
                    TextField("Name", text: $mode.name)
                    Toggle("Show in the menu bar", isOn: $mode.isEnabled)
                    Picker("Model", selection: $mode.model) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    if let price = Pricing.textPrice(for: mode.model) {
                        LabeledContent("Price") {
                            Text(Pricing.describe(price)).foregroundStyle(.secondary)
                        }
                    }
                    activeRow
                }

                Section {
                    TextEditor(text: $mode.prompt)
                        .font(.body)
                        .frame(minHeight: 110, maxHeight: 150)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("Instructions")
                } footer: {
                    SettingsFootnote("Describe how to transform what you say. Your dictation is always passed to the model separately, as text to transform, so spoken words are never treated as instructions.")
                }
            }

            Section {
                LabeledContent("Dictate in this Mode") {
                    ShortcutRecorder(shortcut: $mode.shortcut, conflict: conflict)
                }
            } header: {
                Text("Shortcut")
            } footer: {
                SettingsFootnote("Optional. Dictates once in this Mode without changing the active Mode.")
            }

            if !mode.isDefault {
                Section("Try It") {
                    TextField("Sample", text: $sample, prompt: Text("Type something you might say…"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                    HStack {
                        Button("Run") { Task { await runTest() } }
                            .disabled(sample.isEmpty || mode.prompt.isEmpty || isTesting || !apiKeys.hasKey)
                        if isTesting { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let testOutput {
                        Text(testOutput)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let testError {
                        Text(testError).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var activeRow: some View {
        LabeledContent("Active Mode") {
            if isActive {
                Text("Active").foregroundStyle(.secondary)
            } else {
                Button("Make Active", action: makeActive)
                    .disabled(!mode.isDefault && !mode.isEnabled)
            }
        }
    }

    private var modelChoices: [String] {
        var models = catalog.textModels
        if !mode.model.isEmpty, !models.contains(mode.model) { models.insert(mode.model, at: 0) }
        return models
    }

    private func conflict(_ shortcut: Shortcut) -> String? {
        if shortcut == preferences.shortcut { return "Already used as the main dictation shortcut." }
        return store.modes.first { $0.id != mode.id && $0.shortcut == shortcut }.map { "Already used by the “\($0.name)” Mode." }
    }

    private func runTest() async {
        guard let key = apiKeys.key else { return }
        isTesting = true
        testError = nil
        defer { isTesting = false }
        let started = Date()
        do {
            let output = try await ModeProcessor(client: OpenAIClient(apiKey: key)).process(sample, mode: mode)
            let seconds = Date().timeIntervalSince(started)
            testOutput = output.text
            testError = nil
            Log.app.info("Mode test took \(seconds, format: .fixed(precision: 2))s")
        } catch {
            testOutput = nil
            testError = (error as? OpenAIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
