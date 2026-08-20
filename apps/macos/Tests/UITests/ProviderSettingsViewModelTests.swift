import Testing
import Foundation
import LocalAuthentication
@testable import NotchAgentCore

@Suite("Provider Settings View Model Tests")
@MainActor
struct ProviderSettingsViewModelTests {

    private func makeStore() -> KeystorePasswordStore {
        KeystorePasswordStore(
            keychain: MockKeychainService(),
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-provider-vm-\(UUID().uuidString)", isDirectory: true),
            userDefaults: UserDefaults(suiteName: "notch-provider-vm-\(UUID().uuidString)")!
        )
    }

    @Test("Saves valid fields and forwards the exact runtime configuration")
    func savesValidConfiguration() async throws {
        let store = makeStore()
        let vm = ProviderSettingsViewModel(passwordStore: store)
        vm.baseURL = "http://localhost:1234/v1"
        vm.model = "local-model"
        let testAPIKey = ["sk", "local", "test"].joined(separator: "-")
        vm.apiKeyInput = testAPIKey
        var forwarded: OpenAIProviderConfiguration?
        vm.onConfigurationSaved = { configuration in
            forwarded = configuration
        }

        await vm.save()

        #expect(vm.errorMessage == nil)
        #expect(vm.isSaved)
        #expect(store.loadOpenAIBaseURL() == "http://localhost:1234/v1")
        #expect(store.loadOpenAIModel() == "local-model")
        #expect(store.loadOpenAIAPIKey() == testAPIKey)
        #expect(forwarded?.baseURL == "http://localhost:1234/v1")
        #expect(forwarded?.model == "local-model")
        #expect(forwarded?.apiKey == testAPIKey)
        #expect(vm.apiKeyInput.isEmpty)
    }

    @Test("Does not persist an invalid provider configuration")
    func rejectsInvalidConfiguration() async {
        let store = makeStore()
        let vm = ProviderSettingsViewModel(passwordStore: store)
        vm.baseURL = "http://remote.example.com/v1"
        vm.model = "model"

        await vm.save()

        #expect(vm.errorMessage != nil)
        #expect(!vm.isSaved)
        #expect(store.loadOpenAIBaseURL() == nil)
        #expect(store.loadOpenAIModel() == nil)
    }

    @Test("Blank API key input clears a previous Keychain key for a keyless provider")
    func clearsStaleAPIKey() async throws {
        let store = makeStore()
        try store.saveOpenAIProvider(
            baseURL: "https://provider.example/v1",
            model: "remote-model",
            apiKey: "old-secret"
        )
        let vm = ProviderSettingsViewModel(passwordStore: store)
        vm.baseURL = "http://127.0.0.1:11434/v1"
        vm.model = "local-model"
        vm.apiKeyInput = ""

        await vm.save()

        #expect(vm.errorMessage == nil)
        #expect(!store.hasOpenAIAPIKey)
        #expect(vm.hasStoredAPIKey == false)
    }

    @Test("Keeps the keyless transition failed when Keychain deletion fails")
    func doesNotClaimKeyWasClearedWhenKeychainDeletionFails() async throws {
        let keychain = FailingDeleteKeychainService()
        let store = KeystorePasswordStore(
            keychain: keychain,
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-provider-delete-failure-(UUID().uuidString)", isDirectory: true),
            userDefaults: UserDefaults(suiteName: "notch-provider-delete-failure-(UUID().uuidString)")!
        )
        try store.saveOpenAIProvider(
            baseURL: "https://provider.example/v1",
            model: "remote-model",
            apiKey: "old-secret"
        )
        let vm = ProviderSettingsViewModel(passwordStore: store)

        await vm.clearAPIKey()

        #expect(vm.errorMessage != nil)
        #expect(vm.hasStoredAPIKey)
        #expect(store.loadOpenAIAPIKey() == "old-secret")
    }
}

private enum TestKeychainError: Error {
    case deleteFailed
}

private final class FailingDeleteKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: Data] = [:]

    func saveSecret(key: String, data: Data) throws {
        storage[key] = data
    }

    func saveSecret(key: String, data: Data, requireBiometrics: Bool) throws {
        try saveSecret(key: key, data: data)
    }

    func loadSecret(key: String) throws -> Data? {
        storage[key]
    }

    func loadSecret(key: String, authContext: LAContext?) throws -> Data? {
        storage[key]
    }

    func deleteSecret(key: String) throws {
        throw TestKeychainError.deleteFailed
    }

    func exists(key: String) throws -> Bool {
        storage[key] != nil
    }
}
