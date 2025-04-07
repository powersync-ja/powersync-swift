import PowerSyncKotlin

/// Maps a Kermit `Severity` level to a local `LogSeverity`.
///
/// - Parameter severity: The Kermit log severity value from Kotlin.
/// - Returns: The corresponding `LogSeverity` used in Swift.
private func mapKermitSeverity(_ severity: PowerSyncKotlin.Kermit_coreSeverity) -> LogSeverity {
    switch severity {
        case PowerSyncKotlin.Kermit_coreSeverity.verbose:
            return LogSeverity.debug
        case PowerSyncKotlin.Kermit_coreSeverity.debug:
            return LogSeverity.debug
        case PowerSyncKotlin.Kermit_coreSeverity.info:
            return LogSeverity.info
        case PowerSyncKotlin.Kermit_coreSeverity.warn:
            return LogSeverity.warning
        case PowerSyncKotlin.Kermit_coreSeverity.error:
            return LogSeverity.error
        case PowerSyncKotlin.Kermit_coreSeverity.assert:
            return LogSeverity.fault
    }
}

/// Maps a local `LogSeverity` to a Kermit-compatible `Kermit_coreSeverity`.
///
/// - Parameter severity: The Swift-side `LogSeverity`.
/// - Returns: The equivalent Kermit log severity.
private func mapSeverity(_ severity: LogSeverity) -> PowerSyncKotlin.Kermit_coreSeverity {
    switch severity {
        case .debug:
            return PowerSyncKotlin.Kermit_coreSeverity.debug
        case .info:
            return PowerSyncKotlin.Kermit_coreSeverity.info
        case .warning:
            return PowerSyncKotlin.Kermit_coreSeverity.warn
        case .error:
            return PowerSyncKotlin.Kermit_coreSeverity.error
        case .fault:
            return PowerSyncKotlin.Kermit_coreSeverity.assert
    }
}

/// Adapts a Swift `LogWritterProtocol` to Kermit's `LogWriter` interface.
///
/// This allows Kotlin logging (via Kermit) to call into the Swift logging implementation.
private class KermitLogWriterAdapter: Kermit_coreLogWriter {
    /// The underlying Swift log writer to forward log messages to.
    var adapter: LogWriterProtocol
    
    /// Initializes a new adapter.
    ///
    /// - Parameter adapter: A Swift log writer that will handle log output.
    init(adapter: LogWriterProtocol) {
        self.adapter = adapter
        super.init()
    }
    
    /// Called by Kermit to log a message.
    ///
    /// - Parameters:
    ///   - severity: The severity level of the log.
    ///   - message: The content of the log message.
    ///   - tag: An optional string categorizing the log.
    ///   - throwable: An optional Kotlin exception (ignored here).
    override func log(severity: Kermit_coreSeverity, message: String, tag: String, throwable: KotlinThrowable?) {
        adapter.log(
            severity: mapKermitSeverity(severity),
            message: message,
            tag: tag
        )
    }
}

/// A logger implementation that integrates with PowerSync's Kotlin backend using Kermit.
///
/// This class bridges Swift log writers with the Kotlin logging system and supports
/// runtime configuration of severity levels and writer lists.
public class DatabaseLogger: LoggerProtocol {
    /// The underlying Kermit logger instance provided by the PowerSyncKotlin SDK.
    internal let kLogger = PowerSyncKotlin.generateLogger(logger: nil)
    
    /// Initializes a new logger with an optional list of writers.
    ///
    /// - Parameter writers: An array of Swift log writers. Defaults to an empty array.
    init(writers: [any LogWriterProtocol] = []) {
        setWriters(writers)
    }
    
    /// Sets the minimum severity level that will be logged.
    ///
    /// Messages below this level will be ignored.
    ///
    /// - Parameter severity: The minimum `LogSeverity` to allow through.
    public func setMinSeverity(_ severity: LogSeverity) {
        kLogger.mutableConfig.setMinSeverity(
            mapSeverity(severity)
        )
    }
    
    /// Sets the list of log writers that will receive log messages.
    ///
    /// This updates both the internal writer list and the Kermit logger's configuration.
    ///
    /// - Parameter writers: An array of Swift `LogWritterProtocol` implementations.
    public func setWriters(_ writers: [any LogWriterProtocol]) {
        kLogger.mutableConfig.setLogWriterList(
            writers.map { item in KermitLogWriterAdapter(adapter: item) }
        )
    }
    
    /// Logs a debug-level message.
    public func debug(_ message: String, tag: String) {
        kLogger.d(messageString: message, throwable: nil, tag: tag)
    }
    
    /// Logs an info-level message.
    public func info(_ message: String, tag: String) {
        kLogger.i(messageString: message, throwable: nil, tag: tag)
    }
    
    /// Logs a warning-level message.
    public func warning(_ message: String, tag: String) {
        kLogger.w(messageString: message, throwable: nil, tag: tag)
    }
    
    /// Logs an error-level message.
    public func error(_ message: String, tag: String) {
        kLogger.e(messageString: message, throwable: nil, tag: tag)
    }
    
    /// Logs a fault (assert-level) message, typically used for critical issues.
    public func fault(_ message: String, tag: String) {
        kLogger.a(messageString: message, throwable: nil, tag: tag)
    }
}
