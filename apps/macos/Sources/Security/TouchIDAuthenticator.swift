import Foundation
import LocalAuthentication

/// Errors encountered during Touch ID or biometric authentication.
public enum AuthenticationError: Error, LocalizedError, Equatable {
    case biometricsNotAvailable
    case biometricsNotEnrolled
    case userCancelled
    case authenticationFailed(String)
    case contextInvalidated

    public var errorDescription: String? {
        switch self {
        case .biometricsNotAvailable:
            return "Touch ID / Biometrics are not available on this Mac."
        case .biometricsNotEnrolled:
            return "Touch ID / Biometrics are not enrolled on this Mac."
        case .userCancelled:
            return "User cancelled the authentication prompt."
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .contextInvalidated:
            return "The authentication context was invalidated."
        }
    }
}

/// Protocol defining biometric and device owner authentication.
public protocol TouchIDAuthenticatorProtocol: Sendable {
    func canAuthenticateWithBiometrics() -> Bool
    func authenticateUser(reason: String) async throws -> Bool
}

/// Production implementation of Touch ID and system authentication using LocalAuthentication.
public final class TouchIDAuthenticator: TouchIDAuthenticatorProtocol, @unchecked Sendable {

    public init() {}

    /// Checks if the hardware supports and is enrolled for biometric authentication.
    public func canAuthenticateWithBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Prompts the user for biometric (Touch ID) or passcode authentication with a localized reason.
    public func authenticateUser(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Password"

        var error: NSError?
        let policy: LAPolicy
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            policy = .deviceOwnerAuthentication
        } else {
            if let laError = error as? LAError {
                if laError.code == .biometryNotEnrolled {
                    throw AuthenticationError.biometricsNotEnrolled
                }
            }
            throw AuthenticationError.biometricsNotAvailable
        }

        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw AuthenticationError.userCancelled
            case .biometryNotAvailable:
                throw AuthenticationError.biometricsNotAvailable
            case .biometryNotEnrolled:
                throw AuthenticationError.biometricsNotEnrolled
            case .invalidContext:
                throw AuthenticationError.contextInvalidated
            default:
                throw AuthenticationError.authenticationFailed(laError.localizedDescription)
            }
        } catch {
            throw AuthenticationError.authenticationFailed(error.localizedDescription)
        }
    }
}

/// Mock TouchIDAuthenticator for deterministic unit testing and CI test runners.
public final class MockTouchIDAuthenticator: TouchIDAuthenticatorProtocol, @unchecked Sendable {
    public var shouldSucceed: Bool
    public var canUseBiometrics: Bool

    public init(shouldSucceed: Bool = true, canUseBiometrics: Bool = true) {
        self.shouldSucceed = shouldSucceed
        self.canUseBiometrics = canUseBiometrics
    }

    public func canAuthenticateWithBiometrics() -> Bool {
        return canUseBiometrics
    }

    public func authenticateUser(reason: String) async throws -> Bool {
        if shouldSucceed {
            return true
        } else {
            throw AuthenticationError.userCancelled
        }
    }
}
