@testable import PowerSync
import XCTest

final class ConnectTests: XCTestCase {
    private var database: (any PowerSyncDatabaseProtocol)!
    private var schema: Schema!

    override func setUp() async throws {
        try await super.setUp()
        schema = Schema(tables: [
            Table(
                name: "users",
                columns: [
                    .text("name"),
                    .text("email"),
                    .text("photo_id"),
                ]
            ),
        ])

        database = KotlinPowerSyncDatabaseImpl(
            schema: schema,
            dbFilename: ":memory:",
            logger: DatabaseLogger(DefaultLogger())
        )
        try await database.disconnectAndClear()
    }

    override func tearDown() async throws {
        try await database.disconnectAndClear()
        try await database.close()
        database = nil
        try await super.tearDown()
    }

    /// Tests passing basic JSON as client parameters
    func testClientParameters() async throws {
        /// This is an example of specifying JSON client params.
        /// The test here just ensures that the Kotlin SDK accepts these params and does not crash
        try await database.connect(
            connector: PowerSyncBackendConnector(),
            params: [
                "foo": .string("bar"),
            ]
        )
    }

    func testSyncStatus() async throws {
        XCTAssert(database.currentStatus.connected == false)
        XCTAssert(database.currentStatus.connecting == false)

        try await database.connect(
            connector: PowerSyncBackendConnector()
        )

        try await waitFor(timeout: 10) {
            guard database.currentStatus.connecting == true else {
                throw WaitForMatchError.predicateFail(message: "Should be connecting")
            }
        }
        
        try await database.disconnect()
        
        try await waitFor(timeout: 10) {
            guard database.currentStatus.connecting == false else {
                throw WaitForMatchError.predicateFail(message: "Should not be connecting after disconnect")
            }
        }
    }
    
    func testSyncStatusUpdates() async throws {
        let expectation = XCTestExpectation(
            description: "Watch Sync Status"
        )
        
        let watchTask = Task {
            for try await _ in database.currentStatus.asFlow() {
                expectation.fulfill()
            }
        }
        
        // Do some connecting operations
        try await database.connect(
            connector: PowerSyncBackendConnector()
        )
        
        // We should get an update
        await fulfillment(of: [expectation], timeout: 5)
        watchTask.cancel()
    }
    
    func testSyncHTTPLogs() async throws {
        let expectation = XCTestExpectation(
            description: "Should log a request to the PowerSync endpoint"
        )
        
        let fakeUrl = "https://fakepowersyncinstance.fakepowersync.local"
        
        class TestConnector: PowerSyncBackendConnector {
            let url: String
            
            init(url: String) {
                self.url = url
            }
            
            override func fetchCredentials() async throws -> PowerSyncCredentials? {
                PowerSyncCredentials(
                    endpoint: url,
                    token: "123"
                )
            }
        }
        
        try await database.connect(
            connector: TestConnector(url: fakeUrl),
            options: ConnectOptions(
                clientConfiguration: SyncClientConfiguration(
                    requestLogger: SyncRequestLoggerConfiguration(
                        requestLevel: .all
                    ) { message in
                        // We want to see a request to the specified instance
                        if message.contains(fakeUrl) {
                            expectation.fulfill()
                        }
                    }
                )
            )
        )
        
        await fulfillment(of: [expectation], timeout: 5)
    }
}
