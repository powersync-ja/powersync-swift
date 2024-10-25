import Auth
import SwiftUI
import Supabase
import PowerSyncSwift
import PowerSync
import AnyCodable

@Observable
class SupabaseConnector: PowerSyncBackendConnector {
    let powerSyncEndpoint: String = Secrets.powerSyncEndpoint
    let client: SupabaseClient = SupabaseClient(supabaseURL: Secrets.supabaseURL, supabaseKey: Secrets.supabaseAnonKey)
    var session: Session?

    @ObservationIgnored
    private var observeAuthStateChangesTask: Task<Void, Error>?

    override init() {
        super.init()

        observeAuthStateChangesTask = Task { [weak self] in
            guard let self = self else { return }

            for await (event, session) in self.client.auth.authStateChanges {
                guard [.initialSession, .signedIn, .signedOut].contains(event) else { throw AuthError.sessionMissing }

                self.session = session
            }
        }
    }

    var currentUserID: String {
        guard let id = session?.user.id else {
            preconditionFailure("Required session.")
        }

        return id.uuidString.lowercased()
    }

    override func fetchCredentials() async throws -> PowerSyncCredentials? {
        session = try await client.auth.session

        if (self.session == nil) {
            throw AuthError.sessionMissing
        }

        let token = session!.accessToken

        // userId is for debugging purposes only
        return PowerSyncCredentials(endpoint: self.powerSyncEndpoint, token: token, userId: currentUserID)
    }

    override func uploadData(database: PowerSyncDatabase) async throws {

        guard let transaction = try await database.getNextCrudTransaction() else { return }

        var lastEntry: CrudEntry?
        do {
            for entry in transaction.crud {
                lastEntry = entry
                let tableName = entry.table

                let table = client.from(tableName)

                switch entry.op {
                case .put:
                    var data: [String: AnyCodable] = entry.opData?.mapValues { AnyCodable($0) } ?? [:]
                    data["id"] = AnyCodable(entry.id)
                    try await table.upsert(data).execute();
                case .patch:
                    guard let opData = entry.opData else { continue }
                    let encodableData = opData.mapValues { AnyCodable($0) }
                    try await table.update(encodableData).eq("id", value: entry.id).execute()
                case .delete:
                    try await table.delete().eq( "id", value: entry.id).execute()
                }
            }

            try await transaction.complete.invoke(p1: nil)

        } catch {
            print("Data upload error - retrying last entry: \(lastEntry!), \(error)")
            throw error
        }
    }

    deinit {
        observeAuthStateChangesTask?.cancel()
    }
}
