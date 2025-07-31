import PowerSyncKotlin

extension NetworkLogLevel {
    func toKotlin() -> SwiftNetworkLogLevel {
        switch self {
            case .all:
                return SwiftNetworkLogLevel.all
            case .headers:
                return SwiftNetworkLogLevel.headers
            case .body:
                return SwiftNetworkLogLevel.body
            case .info:
                return SwiftNetworkLogLevel.info
            case .none:
                return SwiftNetworkLogLevel.none
        }
    }
}

extension NetworkLoggerConfig {
    func toKotlinConfig() -> SwiftNetworkLoggerConfig {
        return SwiftNetworkLoggerConfig(
            logLevel: self.logLevel.toKotlin(),
            log: { [logger] message in
                logger.log(message)
            }
        )
    }
}
