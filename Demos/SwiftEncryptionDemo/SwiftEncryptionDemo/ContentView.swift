import SwiftUI
import PowerSync

enum DatabaseOpenState {
    case loading
    case opened(String)
    case error(Error)
}

struct ContentView: View {
    @State var state = DatabaseOpenState.loading
    
    var body: some View {
        VStack {
            switch state {
            case .loading:
                ProgressView()
            case .opened(let cipher):
                Image(systemName: "lock.circle")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Opened encrypted database using \(cipher)")
            case .error(let error):
                Text("Error opening database: \(error.localizedDescription)")
            }
        }
        .padding()
        .task {
            let ps = PowerSyncDatabase(
                schema: Schema(tables: [
                    Table(
                        name: "users",
                        columns: [
                            .text("name")
                        ]
                    ),
                ]),
                // Note: This is for demo purposes. In real apps, follow best practices instead of hardcoding keys in
                // code (e.g. by storing it in Keychain).
                initialStatements: ["pragma key = 'my encryption key'"]
            )
            do {
                let cipher = try await ps.get("PRAGMA cipher", mapper: {cursor in try cursor.getString(index: 0)})
                print("PRAGMA cipher output: \(cipher)")

                try await ps.execute(
                    sql: "INSERT INTO users (id, name) VALUES (uuid(), ?)",
                    parameters: ["Secret user"]
                )
                try await ps.close()
                state = .opened(cipher)
            } catch {
                state = .error(error)
            }
        }
    }
}
