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
/// the PowerSync session. The `requestLevel` determines which network events
/// are logged.
///
/// - Note: The request levell cannot be changed after initialization. A new call to `PowerSyncDatabase.connect` is required to change the level.
public struct SyncRequestLoggerConfiguration {
    /// The request logging level that determines which network events are logged.
    /// Set once during initialization and used throughout the session.
    public let requestLevel: SyncRequestLogLevel
    
    private let logHandler: (_ message: String) -> Void
    
    /// Creates a new network logger configuration.
    /// - Parameters:
    ///   - requestLevel: The `SyncRequestLogLevel` to use for filtering log messages
    ///   - logHandler: A  closure which handles log messages
    public init(
        requestLevel: SyncRequestLogLevel,
        logHandler: @escaping (_ message: String) -> Void)
    {
        self.requestLevel = requestLevel
        self.logHandler = logHandler
    }
    
    public func log(_ message: String) {
        logHandler(message)
    }
    
    /// Creates a new network logger configuration using a `LoggerProtocol` instance.
    ///
    /// This initializer allows integration with an existing logging framework by adapting
    /// a `LoggerProtocol` to conform to `SyncRequestLogger`. The specified `logSeverity`
    /// controls the severity level at which log messages are recorded. An optional `logTag`
    /// may be used to help categorize logs.
    ///
    /// - Parameters:
    ///   - requestLevel: The `SyncRequestLogLevel` to use for filtering which network events are logged.
    ///   - logger: An object conforming to `LoggerProtocol` that will receive log messages.
    ///   - logSeverity: The severity level to use for all log messages (defaults to `.debug`).
    ///   - logTag: An optional tag to include with each log message, for use by the logging backend.
    public init(
        requestLevel: SyncRequestLogLevel,
        logger: LoggerProtocol,
        logSeverity: LogSeverity = .debug,
        logTag: String? = nil)
    {
        self.requestLevel = requestLevel
        self.logHandler = { message in
            switch logSeverity {
                case .debug:
                    logger.debug(message, tag: logTag)
                case .info:
                    logger.info(message, tag: logTag)
                case .warning:
                    logger.warning(message, tag: logTag)
                case .error:
                    logger.error(message, tag: logTag)
                case .fault:
                    logger.fault(message, tag: logTag)
            }
        }
    }
}
