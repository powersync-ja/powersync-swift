import Foundation


///
/// Temporary credentials to connect to the PowerSync service.
///
public struct PowerSyncCredentials: Codable {
    /// PowerSync endpoint, e.g. "https://myinstance.powersync.co".
    public let endpoint: String

    /// Temporary token to authenticate against the service.
    public let token: String

    /// User ID.
    public let userId: String?

    public init(endpoint: String, token: String, userId: String? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.userId = userId
    }

    internal init(kotlin: KotlinPowerSyncCredentials) {
        self.endpoint = kotlin.endpoint
        self.token = kotlin.token
        self.userId = kotlin.userId
    }

    internal var kotlinCredentials: KotlinPowerSyncCredentials {
        return KotlinPowerSyncCredentials(endpoint: endpoint, token: token, userId: userId)
    }

    public func endpointUri(path: String) -> String {
        return "\(endpoint)/\(path)"
    }
}

extension PowerSyncCredentials: CustomStringConvertible {
    public var description: String {
        return "PowerSyncCredentials<endpoint: \(endpoint) userId: \(userId ?? "nil")>"
    }
}
