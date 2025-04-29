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
    @available(*, deprecated, message: "This value is not used anymore.")
    public let userId: String? = nil
    
    enum CodingKeys: String, CodingKey {
           case endpoint
            case token
       }

    @available(*, deprecated, message: "Use init(endpoint:token:) instead. `userId` is no longer used.")
    public init(
        endpoint: String,
        token: String,
        userId: String? = nil) {
        self.endpoint = endpoint
        self.token = token
    }

    public init(endpoint: String, token: String) {
        self.endpoint = endpoint
        self.token = token
    }

    internal init(kotlin: KotlinPowerSyncCredentials) {
        self.endpoint = kotlin.endpoint
        self.token = kotlin.token
    }

    internal var kotlinCredentials: KotlinPowerSyncCredentials {
        return KotlinPowerSyncCredentials(endpoint: endpoint, token: token, userId: nil)
    }

    public func endpointUri(path: String) -> String {
        return "\(endpoint)/\(path)"
    }
}

extension PowerSyncCredentials: CustomStringConvertible {
    public var description: String {
        return "PowerSyncCredentials<endpoint: \(endpoint))>"
    }
}
