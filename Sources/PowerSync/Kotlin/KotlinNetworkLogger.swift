import PowerSyncKotlin

extension SyncRequestLogLevel {
    func toKotlin() -> SwiftSyncRequestLogLevel {
        switch self {
            case .all:
                return SwiftSyncRequestLogLevel.all
            case .headers:
                return SwiftSyncRequestLogLevel.headers
            case .body:
                return SwiftSyncRequestLogLevel.body
            case .info:
                return SwiftSyncRequestLogLevel.info
            case .none:
                return SwiftSyncRequestLogLevel.none
        }
    }
}

extension SyncRequestLoggerConfiguration {
    func toKotlinConfig() -> SwiftRequestLoggerConfig {
        return SwiftRequestLoggerConfig(
            logLevel: self.logLevel.toKotlin(),
            log: { [logger] message in
                logger.log(message)
            }
        )
    }
}
