import OSLog

/// A log writer that bridges custom `LogSeverity` levels to Apple's unified `Logger` framework.
///
/// This writer uses `os.Logger` on iOS 14+ and falls back to `print` for earlier versions.
/// Tags are optionally prefixed to messages in square brackets.
public class SwiftLogWriter: LogWriterProtocol {
    
    /// Logs a message with a given severity and optional tag.
       ///
       /// - Parameters:
       ///   - severity: The severity level of the message.
       ///   - message: The content of the log message.
       ///   - tag: An optional tag used to categorize the message. If empty, no brackets are shown.
    public func log(severity: LogSeverity, message: String, tag: String) {
        let tagPrefix = tag.isEmpty ? "" : "[\(tag)] "
        let message = "\(tagPrefix) \(message)"
        if #available(iOS 14.0, *) {
            let l = Logger()
            
            switch severity {
                case .info:
                    l.info("\(message)")
                case .error:
                    l.error("\(message)")
                case .debug:
                    l.debug("\(message)")
                case .warning:
                    l.warning("\(message)")
                case .fault:
                    l.fault("\(message)")
            }
        } else {
            print("\(severity.rawValue): \(message)")
        }
    }
}

/// A default logger configuration that uses `SwiftLogWritter` and filters messages by minimum severity.
///
/// This logger integrates with your custom logging system and uses `os.Logger` under the hood.
public class DefaultLogger: DatabaseLogger {
    
    /// Initializes the default logger with an optional minimum severity level.
    ///
    /// - Parameter minSeverity: The minimum severity level to log. Defaults to `.debug`.
    public init(minSeverity: LogSeverity = .debug) {
        super.init()
        setMinSeverity(minSeverity)
        setWriters([SwiftLogWriter()])
    }
}
