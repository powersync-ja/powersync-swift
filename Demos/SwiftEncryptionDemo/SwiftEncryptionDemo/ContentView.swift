import SwiftUI
import PowerSync

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
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
            } catch {
                print("error")
            }
        }
    }
}
