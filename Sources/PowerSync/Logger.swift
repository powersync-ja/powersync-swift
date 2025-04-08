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
    public func log(severity: LogSeverity, message: String, tag: String?) {
        let tagPrefix: String
        if let tag, !tag.isEmpty {
            tagPrefix = "[\(tag)] "
        } else {
            tagPrefix = ""
        }
        
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
            print("\(severity.stringValue): \(message)")
        }
    }
}

/// A default logger configuration that uses `PrintLogWritter` and filters messages by minimum severity.
public class DefaultLogger: LoggerProtocol {
    public var minSeverity: LogSeverity
    public var writers: [any LogWriterProtocol]
    
    /// Initializes the default logger with an optional minimum severity level.
    ///
    /// - Parameters
    ///     - minSeverity: The minimum severity level to log. Defaults to `.debug`.
    ///     - writers: Optional writers which logs should be written to. Defaults to a `PrintLogWriter`.
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
    
    
    public func debug(_ message: String, tag: String? = nil) {
        self.writeLog(message, severity: LogSeverity.debug, tag: tag)
    }
    
    public func error(_ message: String, tag: String? = nil) {
        self.writeLog(message, severity: LogSeverity.error, tag: tag)
    }
    
    public func info(_ message: String, tag: String? = nil) {
        self.writeLog(message, severity: LogSeverity.info, tag: tag)
    }
    
    public func warning(_ message: String, tag: String? = nil) {
        self.writeLog(message, severity: LogSeverity.warning, tag: tag)
    }
    
    public func fault(_ message: String, tag: String? = nil) {
        self.writeLog(message, severity: LogSeverity.fault, tag: tag)
    }
    
    private func writeLog(_ message: String, severity: LogSeverity, tag: String?) {
        if (severity.rawValue < self.minSeverirty.rawValue) {
            return
        }
        
        for writer in self.writers {
            writer.log(severity: severity, message: message, tag: tag)
        }
    }
}
