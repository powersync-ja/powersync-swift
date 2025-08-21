import OSLog

/// A log writer which prints to the standard output
///
/// This writer uses `os.Logger` on iOS/macOS/tvOS/watchOS 14+ and falls back to `print` for earlier versions.
public class PrintLogWriter: LogWriterProtocol {
    private let subsystem: String
    private let category: String
    private lazy var logger: Any? = {
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            return Logger(subsystem: subsystem, category: category)
        }
        return nil
    }()

    /// Creates a new PrintLogWriter
    /// - Parameters:
    ///   - subsystem: The subsystem identifier (typically reverse DNS notation of your app)
    ///   - category: The category within your subsystem
    public init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.powersync.logger",
                category: String = "default")
    {
        self.subsystem = subsystem
        self.category = category
    }

    /// Logs a message with a given severity and optional tag.
    /// - Parameters:
    ///   - severity: The severity level of the message.
    ///   - message: The content of the log message.
    ///   - tag: An optional tag used to categorize the message. If empty, no brackets are shown.
    public func log(severity: LogSeverity, message: String, tag: String?) {
        let tagPrefix = tag.map { !$0.isEmpty ? "[\($0)] " : "" } ?? ""
        let formattedMessage = "\(tagPrefix)\(message)"

        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            guard let logger = logger as? Logger else { return }

            switch severity {
            case .info:
                logger.info("\(formattedMessage, privacy: .public)")
            case .error:
                logger.error("\(formattedMessage, privacy: .public)")
            case .debug:
                logger.debug("\(formattedMessage, privacy: .public)")
            case .warning:
                logger.warning("\(formattedMessage, privacy: .public)")
            case .fault:
                logger.fault("\(formattedMessage, privacy: .public)")
            }
        } else {
            print("\(severity.stringValue): \(formattedMessage)")
        }
    }
}

/// A default logger configuration that uses `PrintLogWriter` and filters messages by minimum severity.
public final class DefaultLogger: LoggerProtocol,
    // The shared state is guarded by the DispatchQueue
    @unchecked Sendable
{
    private var minSeverity: LogSeverity
    private var writers: [any LogWriterProtocol]
    private let queue = DispatchQueue(label: "DefaultLogger.queue")

    /// Initializes the default logger with an optional minimum severity level.
    ///
    /// - Parameters
    ///     - minSeverity: The minimum severity level to log. Defaults to `.debug`.
    ///     - writers: Optional writers which logs should be written to. Defaults to a `PrintLogWriter`.
    public init(minSeverity: LogSeverity = .debug, writers: [any LogWriterProtocol]? = nil) {
        self.writers = writers ?? [PrintLogWriter()]
        self.minSeverity = minSeverity
    }

    public func setWriters(_ writers: [any LogWriterProtocol]) {
        queue.sync {
            self.writers = writers
        }
    }

    public func setMinSeverity(_ severity: LogSeverity) {
        queue.sync {
            minSeverity = severity
        }
    }

    public func debug(_ message: String, tag: String? = nil) {
        writeLog(message, severity: LogSeverity.debug, tag: tag)
    }

    public func error(_ message: String, tag: String? = nil) {
        writeLog(message, severity: LogSeverity.error, tag: tag)
    }

    public func info(_ message: String, tag: String? = nil) {
        writeLog(message, severity: LogSeverity.info, tag: tag)
    }

    public func warning(_ message: String, tag: String? = nil) {
        writeLog(message, severity: LogSeverity.warning, tag: tag)
    }

    public func fault(_ message: String, tag: String? = nil) {
        writeLog(message, severity: LogSeverity.fault, tag: tag)
    }

    private func writeLog(_ message: String, severity: LogSeverity, tag: String?) {
        let currentSeverity = queue.sync { minSeverity }

        if severity.rawValue < currentSeverity.rawValue {
            return
        }

        for writer in writers {
            writer.log(severity: severity, message: message, tag: tag)
        }
    }
}
