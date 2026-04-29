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

        database = openKotlinDBDefault(
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

    func testSendableConnect() async throws {
        /// This is just a basic sanity check to confirm that these protocols are
        /// correctly defined as Sendable.
        /// Declaring this struct as Sendable means all its
        /// sub items should be sendable
        struct SendableTest: Sendable {
            let schema: Schema
            let connectOptions: ConnectOptions
        }

        let testOptions = SendableTest(
            schema: Schema(
                tables: [
                    Table(
                        name: "users",
                        columns: [
                            Column(
                                name: "name",
                                type: .text
                            )
                        ]
                    )
                ]
            ),
            connectOptions: ConnectOptions(
                crudThrottle: 1,
                retryDelay: 1,
                params: ["Name": .string("AName")],
                clientConfiguration: SyncClientConfiguration(
                    requestLogger: SyncRequestLoggerConfiguration(
                        requestLevel: .all,
                        logger: database.logger
                    ))
            )
        )

        try await database.updateSchema(
            schema: testOptions.schema
        )

        try await database.connect(
            connector: MockConnector(),
            options: testOptions.connectOptions
        )
    }
}
