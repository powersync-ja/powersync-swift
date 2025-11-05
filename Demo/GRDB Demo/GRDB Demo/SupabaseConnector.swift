import Auth
import PowerSync
import Supabase
import SwiftUI

@MainActor // _session is mutable, limiting to the MainActor satisfies Sendable constraints
final class SupabaseConnector: PowerSyncBackendConnectorProtocol {
    let supabase: SupabaseViewModel
    
    init(
        supabase: SupabaseViewModel
    ) {
        self.supabase = supabase
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let session = supabase.session else {
            return nil
        }
        
        return PowerSyncCredentials(
            endpoint: Secrets.powerSyncEndpoint,
            token: session.accessToken
        )
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let transaction = try await database.getNextCrudTransaction() else { return }

        var lastEntry: CrudEntry?
        do {
            for entry in transaction.crud {
                lastEntry = entry
                let tableName = entry.table

                let table = supabase.client.from(tableName)

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
}


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
