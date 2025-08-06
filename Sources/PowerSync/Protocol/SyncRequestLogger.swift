/// A logger which handles PowerSync network request logs.
///
/// Implement this protocol to receive network request logging messages at the level
/// specified in `SyncRequestLoggerConfiguration`. The `log(_:)` method will be called
/// for each network event that meets the configured logging criteria.
public protocol SyncRequestLogger {
    /// Logs a network-related message.
    /// - Parameter message: The formatted log message to record
    func log(_ message: String)
}

/// Level of logs to expose to a `SyncRequestLogger` handler.
///
/// Controls the verbosity of network logging for PowerSync HTTP requests.
/// The log level is configured once during initialization and determines
/// which network events will be logged throughout the session.
public enum SyncRequestLogLevel {
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
public struct SyncRequestLoggerConfiguration {
    /// The logging level that determines which network events are logged.
    /// Set once during initialization and used throughout the session.
    public let logLevel: SyncRequestLogLevel
    
    /// The logger instance that receives network request log messages.
    /// Must conform to `SyncRequestLogger` protocol.
    public let logger: SyncRequestLogger
    
    /// Creates a new network logger configuration.
    /// - Parameters:
    ///   - logLevel: The `SyncRequestLogLevel` to use for filtering log messages
    ///   - logger: A `SyncRequestLogger` instance to handle log output
    public init(logLevel: SyncRequestLogLevel, logger: SyncRequestLogger) {
        self.logLevel = logLevel
        self.logger = logger
    }
}
