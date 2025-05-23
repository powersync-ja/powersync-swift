import AnyCodable
import Auth
import PowerSync
import Supabase
import SwiftUI

private enum PostgresFatalCodes {
    /// Postgres Response codes that we cannot recover from by retrying.
    static let fatalResponseCodes: [String] = [
        // Class 22 — Data Exception
        // Examples include data type mismatch.
        "22...",
        // Class 23 — Integrity Constraint Violation.
        // Examples include NOT NULL, FOREIGN KEY and UNIQUE violations.
        "23...",
        // INSUFFICIENT PRIVILEGE - typically a row-level security violation
        "42501",
    ]

    static func isFatalError(_ code: String) -> Bool {
        return fatalResponseCodes.contains { pattern in
            code.range(of: pattern, options: [.regularExpression]) != nil
        }
    }

    static func extractErrorCode(from error: any Error) -> String? {
        // Look for code: Optional("XXXXX") pattern
        let errorString = String(describing: error)
        if let range = errorString.range(of: "code: Optional\\(\"([^\"]+)\"\\)", options: .regularExpression),
           let codeRange = errorString[range].range(of: "\"([^\"]+)\"", options: .regularExpression)
        {
            // Extract just the code from within the quotes
            let code = errorString[codeRange].dropFirst().dropLast()
            return String(code)
        }
        return nil
    }
}

@Observable
class SupabaseConnector: PowerSyncBackendConnector {
    let powerSyncEndpoint: String = Secrets.powerSyncEndpoint
    let client: SupabaseClient = .init(supabaseURL: Secrets.supabaseURL, supabaseKey: Secrets.supabaseAnonKey)
    var session: Session?
    private var errorCode: String?

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

    func getStorageBucket() -> StorageFileApi? {
        guard let bucket = Secrets.supabaseStorageBucket else {
            return nil
        }
        
        return client.storage.from(bucket)       
    }

    override func fetchCredentials() async throws -> PowerSyncCredentials? {
        session = try await client.auth.session

        if session == nil {
            throw AuthError.sessionMissing
        }

        let token = session!.accessToken

        return PowerSyncCredentials(endpoint: powerSyncEndpoint, token: token)
    }

    override func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let transaction = try await database.getNextCrudTransaction() else { return }

        var lastEntry: CrudEntry?
        do {
            for entry in transaction.crud {
                lastEntry = entry
                let tableName = entry.table

                let table = client.from(tableName)

                switch entry.op {
                case .put:
                    var data = entry.opData ?? [:]
                    data["id"] = entry.id
                    try await table.upsert(data).execute()
                case .patch:
                    guard let opData = entry.opData else { continue }
                    try await table.update(opData).eq("id", value: entry.id).execute()
                case .delete:
                    try await table.delete().eq("id", value: entry.id).execute()
                }
            }

            try await transaction.complete()

        } catch {
            if let errorCode = PostgresFatalCodes.extractErrorCode(from: error),
               PostgresFatalCodes.isFatalError(errorCode)
            {
                /// Instead of blocking the queue with these errors,
                /// discard the (rest of the) transaction.
                ///
                /// Note that these errors typically indicate a bug in the application.
                /// If protecting against data loss is important, save the failing records
                /// elsewhere instead of discarding, and/or notify the user.
                print("Data upload error: \(error)")
                print("Discarding entry: \(lastEntry!)")
                try await transaction.complete()
                return
            }

            print("Data upload error - retrying last entry: \(lastEntry!), \(error)")
            throw error
        }
    }

    deinit {
        observeAuthStateChangesTask?.cancel()
    }
}
