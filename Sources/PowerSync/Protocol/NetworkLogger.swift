/// A logger which handles PowerSync network request logs.
///
/// Implement this protocol to receive network logging messages at the level
/// specified in `NetworkLoggerConfig`. The `log(_:)` method will be called
/// for each network event that meets the configured logging criteria.
public protocol NetworkLogger {
    /// Logs a network-related message.
    /// - Parameter message: The formatted log message to record
    func log(_ message: String)
}

/// Level of logs to expose to a `NetworkLogger` handler.
///
/// Controls the verbosity of network logging for PowerSync HTTP requests.
/// The log level is configured once during initialization and determines
/// which network events will be logged throughout the session.
public enum NetworkLogLevel {
    /// Log all network activity including headers, body, and info
    case all
    /// Log only request/response headers
    case headers
    /// Log only request/response body content
    case body
    /// Log basic informational messages about requests
    case info
    /// Disable all network logging
    case none
}

/// Configuration for PowerSync HTTP request logging.
///
/// This configuration is set once during initialization and used throughout
/// the PowerSync session. The `logLevel` determines which network events
/// are logged, while the `logger` handles the actual log output.
///
/// - Note: The log level cannot be changed after initialization. A new call to `PowerSyncDatabase.connect` is required to change the level.
public struct NetworkLoggerConfig {
    /// The logging level that determines which network events are logged.
    /// Set once during initialization and used throughout the session.
    public let logLevel: NetworkLogLevel
    
    /// The logger instance that receives network log messages.
    /// Must conform to `NetworkLogger` protocol.
    public let logger: NetworkLogger
    
    /// Creates a new network logger configuration.
    /// - Parameters:
    ///   - logLevel: The `NetworkLogLevel` to use for filtering log messages
    ///   - logger: A `NetworkLogger` instance to handle log output
    public init(logLevel: NetworkLogLevel, logger: NetworkLogger) {
        self.logLevel = logLevel
        self.logger = logger
    }
}
