import SwiftUI

private enum ProviderSettingsPersistenceError: Error, LocalizedError {
    case runtimeRollbackFailed

    var errorDescription: String? {
        switch self {
        case .runtimeRollbackFailed:
            return "Provider settings could not be persisted and the agent runtime was disabled for safety. Restart Notch3 after correcting the storage issue."
        }
    }
}

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

    /// Applies a proposed configuration to the runtime before local
    /// persistence. Passing nil is used only for rollback to the runtime's
    /// safe keyless default when no previous provider was stored.
    public var onConfigurationSaved: ((OpenAIProviderConfiguration?) async throws -> Void)?

    /// Called when local persistence fails and the runtime cannot be restored
    /// to its previous configuration. The owner must disable or restart the
    /// runtime so it cannot continue with an uncommitted provider change.
    public var onConfigurationRollbackFailed: (() -> Void)?

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
            let previousConfiguration = passwordStore.loadOpenAIProviderConfiguration()

            if let onConfigurationSaved {
                try await onConfigurationSaved(configuration)
            }
            do {
                try passwordStore.saveOpenAIProvider(
                    baseURL: configuration.baseURL,
                    model: configuration.model,
                    apiKey: configuration.apiKey
                )
            } catch {
                try await restoreRuntimeAfterPersistenceFailure(previousConfiguration)
                throw error
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
        isSaving = true
        errorMessage = nil
        isSaved = false
        defer { isSaving = false }

        do {
            let configuration = try OpenAIProviderConfiguration(
                baseURL: baseURL,
                model: model,
                apiKey: nil
            )
            let previousConfiguration = passwordStore.loadOpenAIProviderConfiguration()

            if let onConfigurationSaved {
                try await onConfigurationSaved(configuration)
            }
            do {
                try passwordStore.saveOpenAIProvider(
                    baseURL: configuration.baseURL,
                    model: configuration.model,
                    apiKey: nil
                )
            } catch {
                try await restoreRuntimeAfterPersistenceFailure(previousConfiguration)
                throw error
            }
            apiKeyInput = ""
            hasStoredAPIKey = passwordStore.hasOpenAIAPIKey
            isSaved = true
        } catch {
            // Keep the stored-key indicator truthful when Keychain deletion or
            // runtime synchronization fails; never claim a secret was cleared.
            hasStoredAPIKey = passwordStore.hasOpenAIAPIKey
            errorMessage = error.localizedDescription
        }
    }

    private func restoreRuntimeAfterPersistenceFailure(
        _ previousConfiguration: OpenAIProviderConfiguration?
    ) async throws {
        guard let onConfigurationSaved else { return }

        do {
            try await onConfigurationSaved(previousConfiguration)
        } catch {
            // A failed rollback means the runtime may still hold the
            // uncommitted provider. Disable it before surfacing the error;
            // silently swallowing this failure would leave storage and the
            // live runtime describing different credentials.
            onConfigurationRollbackFailed?()
            throw ProviderSettingsPersistenceError.runtimeRollbackFailed
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
