@testable import PowerSync
import Testing

@Suite
struct MultipleInstanceTest {
    @Test func warnsAboutMultipleInstances() async throws {
        let pool = AsyncConnectionPool(location: .inMemory, logger: DefaultLogger())
        let logWriter = TestLogWriterAdapter()
        let logger = DefaultLogger(minSeverity: .warning, writers: [logWriter])
        let schema = Schema()

        let a = PowerSyncDatabaseImpl(identifier: "id", logger: logger, pool: pool, httpClient: PlatformHttpClient.shared, schema: schema)
        try #require(logWriter.getLogs().isEmpty)

        let b = PowerSyncDatabaseImpl(identifier: "id", logger: logger, pool: pool, httpClient: PlatformHttpClient.shared, schema: schema)
        let _ = try #require(logWriter.getLogs().first { $0.contains("Multiple PowerSync instances for the same database have been detected.") })
 
        // Ensure databases are kept around until the end of the test (if a gets closed before, we would't see the warning).
        let _ = consume a
        let _ = consume b
    }
    
    @Test func doesNotWarnForClosedInstances() async throws {
        let pool = AsyncConnectionPool(location: .inMemory, logger: DefaultLogger())
        let logWriter = TestLogWriterAdapter()
        let logger = DefaultLogger(minSeverity: .warning, writers: [logWriter])
        let schema = Schema()

        do {
            let _ = PowerSyncDatabaseImpl(identifier: "id2", logger: logger, pool: pool, httpClient: PlatformHttpClient.shared, schema: schema)
        }

        let b = PowerSyncDatabaseImpl(identifier: "id2", logger: logger, pool: pool, httpClient: PlatformHttpClient.shared, schema: schema)
        try #require(logWriter.getLogs().isEmpty)
        let _ = consume b
    }
}
