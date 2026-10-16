import Foundation

enum PortalError: LocalizedError, Sendable {
    case invalidCredentials(String)
    case sessionExpired
    case transport(String)
    case httpStatus(Int, String?)
    case malformedResponse(String)
    case noData
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials(let message):
            return message
        case .sessionExpired:
            return "Your portal session expired. Sign in again."
        case .transport(let message):
            return "Could not reach the E.ON portal. \(message)"
        case .httpStatus(let code, let message):
            if let message, !message.isEmpty { return "Portal returned \(code): \(message)" }
            return "Portal returned HTTP \(code)."
        case .malformedResponse(let detail):
            return "Unexpected response from the portal. \(detail)"
        case .noData:
            return "The portal has no readings for this period yet."
        case .notConfigured(let detail):
            return detail
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .invalidCredentials, .sessionExpired: return true
        default: return false
        }
    }
}
