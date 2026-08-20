import Foundation

/// Validation failures for the user-supplied OpenAI-compatible chat provider.
public enum OpenAIProviderConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case emptyBaseURL
    case invalidURL
    case insecureRemoteURL
    case emptyModel
    case embeddedCredentials
    case queryOrFragmentNotAllowed

    public var errorDescription: String? {
        switch self {
        case .emptyBaseURL:
            return "Provider Base URL is required."
        case .invalidURL:
            return "Provider Base URL must be a valid URL with a host."
        case .insecureRemoteURL:
            return "Remote providers must use HTTPS. HTTP is allowed only for loopback providers."
        case .emptyModel:
            return "Provider model is required."
        case .embeddedCredentials:
            return "Provider URLs must not contain embedded credentials."
        case .queryOrFragmentNotAllowed:
            return "Provider Base URLs must not contain query parameters or fragments; store API keys in Keychain."
        }
    }
}

/// A validated OpenAI-compatible endpoint configuration.
///
/// Remote endpoints are HTTPS-only. Plain HTTP is intentionally limited to
/// localhost/127.0.0.1/::1 so local development providers remain possible
/// without allowing credentials to be sent to an insecure remote host.
public struct OpenAIProviderConfiguration: Codable, Equatable, Sendable {
    public let baseURL: String
    public let model: String
    public let apiKey: String?

    public init(baseURL: String, model: String, apiKey: String? = nil) throws {
        let normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedBaseURL.isEmpty else {
            throw OpenAIProviderConfigurationError.emptyBaseURL
        }
        guard !normalizedModel.isEmpty else {
            throw OpenAIProviderConfigurationError.emptyModel
        }
        guard let url = URL(string: normalizedBaseURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            throw OpenAIProviderConfigurationError.invalidURL
        }
        guard url.user == nil, url.password == nil else {
            throw OpenAIProviderConfigurationError.embeddedCredentials
        }
        guard url.query == nil, url.fragment == nil else {
            throw OpenAIProviderConfigurationError.queryOrFragmentNotAllowed
        }

        let isLoopback = Self.isLoopbackHost(host)
        switch scheme {
        case "https":
            break
        case "http" where isLoopback:
            break
        default:
            throw OpenAIProviderConfigurationError.insecureRemoteURL
        }

        self.baseURL = normalizedBaseURL
        self.model = normalizedModel
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = normalizedAPIKey?.isEmpty == true ? nil : normalizedAPIKey
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        switch host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) {
        case "localhost", "127.0.0.1", "::1":
            return true
        default:
            return false
        }
    }
}
