import PowerSyncKotlin

/// Adapts a Swift `LoggerProtocol` to Kermit's `LogWriter` interface.
///
/// This allows Kotlin logging (via Kermit) to call into the Swift logging implementation.
private class KermitLogWriterAdapter: Kermit_coreLogWriter {
    /// The underlying Swift log writer to forward log messages to.
    let logger: any LoggerProtocol
    
    /// Initializes a new adapter.
    ///
    /// - Parameter logger: A Swift log writer that will handle log output.
    init(logger: any LoggerProtocol) {
        self.logger = logger
        super.init()
    }
    
    /// Called by Kermit to log a message.
    ///
    /// - Parameters:
    ///   - severity: The severity level of the log.
    ///   - message: The content of the log message.
    ///   - tag: A string categorizing the log.
    ///   - throwable: An optional Kotlin exception (ignored here).
    override func log(severity: Kermit_coreSeverity, message: String, tag: String, throwable: KotlinThrowable?) {
        switch severity {
        case PowerSyncKotlin.Kermit_coreSeverity.verbose:
            return logger.debug(message, tag: tag)
        case PowerSyncKotlin.Kermit_coreSeverity.debug:
            return logger.debug(message, tag: tag)
        case PowerSyncKotlin.Kermit_coreSeverity.info:
            return logger.info(message, tag: tag)
        case PowerSyncKotlin.Kermit_coreSeverity.warn:
            return logger.warning(message, tag: tag)
        case PowerSyncKotlin.Kermit_coreSeverity.error:
            return logger.error(message, tag: tag)
        case PowerSyncKotlin.Kermit_coreSeverity.assert:
            return logger.fault(message, tag: tag)
        }
    }
}

/// A logger implementation that integrates with PowerSync's Kotlin core using Kermit.
///
/// This class bridges Swift log writers with the Kotlin logging system and supports
/// runtime configuration of severity levels and writer lists.
internal class DatabaseLogger: LoggerProtocol {
    /// The underlying Kermit logger instance provided by the PowerSyncKotlin SDK.
    public let kLogger = PowerSyncKotlin.generateLogger(logger: nil)
    public let logger: any LoggerProtocol
    
    /// Initializes a new logger with an optional list of writers.
    ///
    /// - Parameter logger: A logger which will be called for each internal log operation
    init(_ logger: any LoggerProtocol) {
        self.logger = logger
        // Set to the lowest severity. The provided logger should filter by severity
        kLogger.mutableConfig.setMinSeverity(Kermit_coreSeverity.verbose)
        kLogger.mutableConfig.setLogWriterList(
            [KermitLogWriterAdapter(logger: logger)]
        )
    }
    
    /// Sets the minimum severity level that will be logged.
    ///
    /// Messages below this level will be ignored.
    ///
    /// - Parameter severity: The minimum `LogSeverity` to allow through.
    public func setMinSeverity(_ severity: LogSeverity) {
        logger.setMinSeverity(severity)
    }
    
    /// Sets the list of log writers that will receive log messages.
    ///
    /// This updates both the internal writer list and the Kermit logger's configuration.
    ///
    /// - Parameter writers: An array of Swift `LogWritterProtocol` implementations.
    public func setWriters(_ writers: [any LogWriterProtocol]) {
        logger.setWriters(writers)
    }
    
    /// Logs a debug-level message.
    public func debug(_ message: String, tag: String?) {
        logger.debug(message, tag: tag)
    }
    
    /// Logs an info-level message.
    public func info(_ message: String, tag: String?) {
        logger.info(message, tag: tag)
    }
    
    /// Logs a warning-level message.
    public func warning(_ message: String, tag: String?) {
        logger.warning(message, tag: tag)
    }
    
    /// Logs an error-level message.
    public func error(_ message: String, tag: String?) {
        logger.error(message, tag: tag)
    }
    
    /// Logs a fault (assert-level) message, typically used for critical issues.
    public func fault(_ message: String, tag: String?) {
        logger.fault(message, tag: tag)
    }
}
