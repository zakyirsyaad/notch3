import SwiftUI

/// View model for the OpenAI-compatible provider settings surface.
///
/// Base URL and model are local preferences. The API key is write-only from
/// the UI: it is accepted once, stored in the dedicated Keychain record, and
/// then cleared from this view model so it cannot be read back into the HUD.
@MainActor
public final class ProviderSettingsViewModel: ObservableObject {
    @Published public var baseURL: String
    @Published public var model: String
    @Published public var apiKeyInput: String = ""
    @Published public private(set) var hasStoredAPIKey: Bool
    @Published public private(set) var isSaving: Bool = false
    @Published public private(set) var isSaved: Bool = false
    @Published public var errorMessage: String?

    public let passwordStore: KeystorePasswordStore

    /// Called after local persistence succeeds so the app delegate can send
    /// the exact `openaiApiKey`, `openaiBaseUrl`, and `openaiModel` fields to
    /// the runtime without exposing the key to the UI.
    public var onConfigurationSaved: ((OpenAIProviderConfiguration) async throws -> Void)?

    public init(passwordStore: KeystorePasswordStore) {
        self.passwordStore = passwordStore
        self.baseURL = passwordStore.loadOpenAIBaseURL() ?? ""
        self.model = passwordStore.loadOpenAIModel() ?? ""
        self.hasStoredAPIKey = passwordStore.hasOpenAIAPIKey
    }

    public var isConfigured: Bool {
        guard let _ = try? OpenAIProviderConfiguration(baseURL: baseURL, model: model) else {
            return false
        }
        return true
    }

    /// Validates and saves the provider. A blank API-key field explicitly
    /// selects a keyless provider and removes any previous Keychain key.
    public func save() async {
        guard !isSaving else { return }
        isSaving = true
        isSaved = false
        errorMessage = nil
        defer { isSaving = false }

        do {
            let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = try OpenAIProviderConfiguration(
                baseURL: baseURL,
                model: model,
                apiKey: key.isEmpty ? nil : key
            )

            try passwordStore.saveOpenAIProvider(
                baseURL: configuration.baseURL,
                model: configuration.model,
                apiKey: configuration.apiKey
            )
            if let onConfigurationSaved {
                try await onConfigurationSaved(configuration)
            }

            // Never retain or display the secret after a save.
            apiKeyInput = ""
            hasStoredAPIKey = passwordStore.hasOpenAIAPIKey
            isSaved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearAPIKey() async {
        guard !isSaving else { return }
        errorMessage = nil
        isSaved = false

        do {
            let configuration = try OpenAIProviderConfiguration(
                baseURL: baseURL,
                model: model,
                apiKey: nil
            )
            try passwordStore.clearOpenAIAPIKey()
            apiKeyInput = ""
            hasStoredAPIKey = false

            if let onConfigurationSaved {
                try await onConfigurationSaved(configuration)
            }
            isSaved = true
        } catch {
            // Keep the stored-key indicator truthful when Keychain deletion or
            // runtime synchronization fails; never claim a secret was cleared.
            hasStoredAPIKey = passwordStore.hasOpenAIAPIKey
            errorMessage = error.localizedDescription
        }
    }
}

/// Compact settings card for an OpenAI-compatible chat provider.
public struct ProviderSettingsView: View {
    @ObservedObject public var viewModel: ProviderSettingsViewModel

    public init(viewModel: ProviderSettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat provider")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(V6Palette.paper)

            Text("Use an OpenAI-compatible endpoint. Remote URLs must use HTTPS; local HTTP is allowed for loopback providers.")
                .font(.system(size: 10))
                .foregroundColor(V6Palette.paper.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            field(label: "Base URL", text: $viewModel.baseURL, prompt: "https://api.openai.com/v1", sensitive: false)
            field(label: "Model", text: $viewModel.model, prompt: "gpt-4o", sensitive: false)
            field(label: "API key (optional)", text: $viewModel.apiKeyInput, prompt: viewModel.hasStoredAPIKey ? "Stored in Keychain" : "Leave blank for local providers", sensitive: true)

            HStack(spacing: 8) {
                Button {
                    Task { await viewModel.save() }
                } label: {
                    Label("Save provider", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isSaving)
                .accessibilityLabel("Save chat provider settings")

                if viewModel.hasStoredAPIKey {
                    Button("Clear API key") {
                        Task { await viewModel.clearAPIKey() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Clear stored API key")
                }

                if viewModel.isSaved {
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }

    @ViewBuilder
    private func field(label: String, text: Binding<String>, prompt: String, sensitive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(V6Palette.paper.opacity(0.65))

            Group {
                if sensitive {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .accessibilityLabel(label)
        }
    }
}
