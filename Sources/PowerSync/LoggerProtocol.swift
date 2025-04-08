public enum LogSeverity: Int, CaseIterable {
    /// Detailed information typically used for debugging.
    case debug = 0

    /// Informational messages that highlight the progress of the application.
    case info = 1

    /// Potentially harmful situations that are not necessarily errors.
    case warning = 2

    /// Error events that might still allow the application to continue running.
    case error = 3

    /// Serious errors indicating critical failures, often unrecoverable.
    case fault = 4

    /// Map severity to its string representation
    public var stringValue: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }

    /// Convert Int to String representation
    public static func string(from intValue: Int) -> String? {
        return LogSeverity(rawValue: intValue)?.stringValue
    }
}

/// A protocol for writing log messages to a specific backend or output.
///
/// Conformers handle the actual writing or forwarding of log messages.
public protocol LogWriterProtocol {
    /// Logs a message with the given severity and optional tag.
    ///
    /// - Parameters:
    ///   - severity: The severity level of the log message.
    ///   - message: The content of the log message.
    ///   - tag: An optional tag to categorize or group the log message.
    func log(severity: LogSeverity, message: String, tag: String?)
}

/// A protocol defining the interface for a logger that supports severity filtering and multiple writers.
///
/// Conformers provide logging APIs and manage attached log writers.
public protocol LoggerProtocol {
    /// Sets the minimum severity level to be logged.
    ///
    /// Log messages below this severity will be ignored.
    ///
    /// - Parameter severity: The minimum severity level to log.
    func setMinSeverity(_ severity: LogSeverity)
    
    /// Sets the list of log writers that will handle log output.
    ///
    /// - Parameter writters: An array of `LogWritterProtocol` conformers.
    func setWriters(_ writters: [LogWriterProtocol])
    
    /// Logs an informational message.
    ///
    /// - Parameters:
    ///   - message: The content of the log message.
    ///   - tag: An optional tag to categorize the message.
    func info(_ message: String, tag: String?)
    
    /// Logs an error message.
    ///
    /// - Parameters:
    ///   - message: The content of the log message.
    ///   - tag: An optional tag to categorize the message.
    func error(_ message: String, tag: String?)
    
    /// Logs a debug message.
    ///
    /// - Parameters:
    ///   - message: The content of the log message.
    ///   - tag: An optional tag to categorize the message.
    func debug(_ message: String, tag: String?)
    
    /// Logs a warning message.
    ///
    /// - Parameters:
    ///   - message: The content of the log message.
    ///   - tag: An optional tag to categorize the message.
    func warning(_ message: String, tag: String?)
    
    /// Logs a fault message, typically used for critical system-level failures.
    ///
    /// - Parameters:
    ///   - message: The content of the log message.
    ///   - tag: An optional tag to categorize the message.
    func fault(_ message: String, tag: String?)
}
