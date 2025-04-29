import Foundation

/// Enum representing errors that can occur in the PowerSync system.
public enum PowerSyncError: Error, LocalizedError {
    
    /// Represents a failure in an operation, potentially with a custom message and an underlying error.
    case operationFailed(message: String? = nil, underlyingError: Error? = nil)
    
    /// A localized description of the error, providing details about the failure.
    public var errorDescription: String? {
        switch self {
        case let .operationFailed(message, underlyingError):
            // Combine message and underlying error description if both are available
            if let message = message, let underlyingError = underlyingError {
                return "\(message): \(underlyingError.localizedDescription)"
            } else if let message = message {
                // Return only the message if no underlying error is available
                return message
            } else if let underlyingError = underlyingError {
                // Return only the underlying error description if no message is provided
                return underlyingError.localizedDescription
            } else {
                // Fallback to a generic error description if neither message nor underlying error is provided
                return "An unknown error occurred."
            }
        }
    }
}
