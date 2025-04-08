import OSLog

/// A log writer which prints to the standard output
///
/// This writer uses `os.Logger` on iOS 14+ and falls back to `print` for earlier versions.
public class PrintLogWriter: LogWriterProtocol {
    
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
public class DefaultLogger: LoggerProtocol {
    public var minSeverirty: LogSeverity
    public var writers: [any LogWriterProtocol]
    
    /// Initializes the default logger with an optional minimum severity level.
    ///
    /// - Parameter minSeverity: The minimum severity level to log. Defaults to `.debug`.
    public init(minSeverity: LogSeverity = .debug, writers: [any LogWriterProtocol]? = nil ) {
        self.writers = writers ?? [ PrintLogWriter() ]
        self.minSeverirty = minSeverity
    }
    
    public func setWriters(_ writters: [any LogWriterProtocol]) {
        self.writers = writters
    }
    
    public func setMinSeverity(_ severity: LogSeverity) {
        self.minSeverirty = severity
    }
    
    
    public func debug(_ message: String, tag: String) {
        self.writeLog(message, tag: tag, severity: LogSeverity.debug)
    }
    
    public func error(_ message: String, tag: String) {
        self.writeLog(message, tag: tag, severity: LogSeverity.error)
    }
    
    public func info(_ message: String, tag: String) {
        self.writeLog(message, tag: tag, severity: LogSeverity.info)
    }
    
    public func warning(_ message: String, tag: String) {
        self.writeLog(message, tag: tag, severity: LogSeverity.warning)
    }
    
    public func fault(_ message: String, tag: String) {
        self.writeLog(message, tag: tag, severity: LogSeverity.fault)
    }
    
    private func writeLog(_ message: String, tag: String, severity: LogSeverity) {
        if (severity.rawValue < self.minSeverirty.rawValue) {
            return
        }
        
        for writer in self.writers {
            writer.log(severity: severity, message: message, tag: tag)
        }
    }
}
