import SwiftUI

struct OpenAISettingsView: View {
    @Environment(APIKeyStore.self) private var apiKeys
    @Environment(Preferences.self) private var preferences
    @Environment(ModelCatalog.self) private var catalog

    @State private var keyInput = ""
    @State private var isReplacing = false
    @State private var status: KeyStatus = .unknown
    @State private var saveError: String?

    enum KeyStatus: Equatable {
        case unknown, checking, valid, invalid(String)
    }

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                if apiKeys.hasKey && !isReplacing {
                    LabeledContent("API key") {
                        HStack(spacing: 8) {
                            statusView
                            Text(apiKeys.maskedKey ?? "Saved")
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Test Key") { Task { await testKey() } }
                            .disabled(status == .checking)
                        Button("Replace…") {
                            keyInput = ""
                            isReplacing = true
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            apiKeys.remove()
                            status = .unknown
                        }
                    }
                } else {
                    SecureField("API key", text: $keyInput, prompt: Text("sk-…"))
                        .onSubmit { Task { await saveKey() } }
                    HStack {
                        Button("Save Key") { Task { await saveKey() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if isReplacing {
                            Button("Cancel") { isReplacing = false }
                        }
                        if status == .checking { ProgressView().controlSize(.small) }
                        Spacer()
                        Link("Get an API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    }
                    if case .invalid(let message) = status {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    if let saveError {
                        Text(saveError).font(.caption).foregroundStyle(.red)
                    }
                }
            } header: {
                Text("API Key")
            } footer: {
                SettingsFootnote("Stored in your macOS Keychain and only ever sent to api.openai.com.")
            }

            Section {
                Picker("Transcription model", selection: $preferences.transcriptionModel) {
                    ForEach(transcriptionChoices, id: \.self) { model in
                        Text(ModelCatalog.displayName(forTranscriptionModel: model)).tag(model)
                    }
                }
            } header: {
                Text("Speech to Text")
            } footer: {
                SettingsFootnote("gpt-transcribe is OpenAI’s newest speech model: the most accurate and the least expensive. Older models are listed for compatibility.")
            }

            Section {
                LabeledContent("Models available for Modes") {
                    HStack(spacing: 8) {
                        if catalog.isRefreshing { ProgressView().controlSize(.small) }
                        Text("\(catalog.textModels.count)")
                        Button("Refresh") { Task { await catalog.refresh(apiKey: apiKeys.key) } }
                            .disabled(!apiKeys.hasKey || catalog.isRefreshing)
                    }
                }
                if let error = catalog.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Modes")
            } footer: {
                SettingsFootnote("Each Mode chooses its own model in the Modes tab. Models are discovered from your OpenAI account.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var transcriptionChoices: [String] {
        var models = catalog.transcriptionModels
        if !models.contains(preferences.transcriptionModel) { models.insert(preferences.transcriptionModel, at: 0) }
        return models
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid(let message):
            Label("Invalid", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private func saveKey() async {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        saveError = nil
        status = .checking
        // Validate before saving so a typo doesn't replace a working key.
        do {
            let models = try await OpenAIClient(apiKey: key).listModels()
            try apiKeys.save(key)
            catalog.apply(models)
            keyInput = ""
            isReplacing = false
            status = .valid
        } catch let error as OpenAIError {
            status = .invalid(error.errorDescription ?? "The key couldn’t be verified.")
            if case .network = error {
                // Offline: keep the key anyway; it will be checked on first use.
                try? apiKeys.save(key)
                keyInput = ""
                isReplacing = false
                status = .unknown
            }
        } catch {
            saveError = error.localizedDescription
            status = .unknown
        }
    }

    private func testKey() async {
        guard let key = apiKeys.key else { return }
        status = .checking
        do {
            let models = try await OpenAIClient(apiKey: key).listModels()
            catalog.apply(models)
            status = .valid
        } catch {
            status = .invalid((error as? OpenAIError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
