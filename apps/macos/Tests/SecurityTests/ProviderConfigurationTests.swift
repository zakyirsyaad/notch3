import Testing
import Foundation
@testable import NotchAgentCore

@Suite("OpenAI Provider Configuration Tests")
struct ProviderConfigurationTests {

    @Test("Accepts HTTPS providers and loopback HTTP providers")
    func acceptsAllowedEndpoints() throws {
        let remote = try OpenAIProviderConfiguration(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o"
        )
        #expect(remote.baseURL == "https://api.openai.com/v1")

        let loopback = try OpenAIProviderConfiguration(
            baseURL: "http://127.0.0.1:1234/v1",
            model: "local-model"
        )
        #expect(loopback.baseURL == "http://127.0.0.1:1234/v1")
    }

    @Test("Rejects insecure remote HTTP, malformed URLs, and empty models")
    func rejectsInvalidConfiguration() {
        #expect(throws: OpenAIProviderConfigurationError.self) {
            try OpenAIProviderConfiguration(baseURL: "http://api.example.com/v1", model: "model")
        }
        #expect(throws: OpenAIProviderConfigurationError.self) {
            try OpenAIProviderConfiguration(baseURL: "not a URL", model: "model")
        }
        #expect(throws: OpenAIProviderConfigurationError.self) {
            try OpenAIProviderConfiguration(baseURL: "https://api.example.com/v1", model: "  ")
        }
        #expect(throws: OpenAIProviderConfigurationError.self) {
            try OpenAIProviderConfiguration(baseURL: "https://api.example.com/v1?api_key=secret", model: "model")
        }
        #expect(throws: OpenAIProviderConfigurationError.self) {
            try OpenAIProviderConfiguration(baseURL: "https://api.example.com/v1#secret", model: "model")
        }
    }

    @Test("Persists provider URL and model locally while keeping API key in a dedicated Keychain record")
    func storesProviderConfigurationWithoutKeyReadback() throws {
        let suiteName = "notch-provider-(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = MockKeychainService()
        let testAPIKey = ["sk", "test", "provider", "key"].joined(separator: "-")
        let store = KeystorePasswordStore(
            keychain: keychain,
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-provider-(UUID().uuidString)", isDirectory: true),
            userDefaults: defaults
        )

        try store.saveOpenAIProvider(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o",
            apiKey: testAPIKey
        )

        #expect(store.loadOpenAIBaseURL() == "https://api.openai.com/v1")
        #expect(store.loadOpenAIModel() == "gpt-4o")
        #expect(store.hasOpenAIAPIKey)
        #expect(store.loadOpenAIAPIKey() == testAPIKey)
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { value in
            !(value is String && (value as? String)?.contains(testAPIKey) == true)
        })
        #expect(try keychain.loadSecret(key: KeystorePasswordStore.openAIAPIKeyKey) != nil)
    }
}
