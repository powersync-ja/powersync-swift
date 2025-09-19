import Foundation
import GRDB
import PowerSync

/// PowerSync client side schema
let todosTable = Table(
    name: "todos",
    columns: [
        .text("name"),
        .text("list_id"),
        // Conversion should automatically be handled by GRDB
        .integer("completed"),
        .text("completed_at")
    ]
)

struct Todo: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var listId: String
    var isCompleted: Bool
    var completedAt: Date?

    static var databaseTableName = "todos"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case listId = "list_id"
        case isCompleted = "completed"
        case completedAt = "completed_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let listId = Column(CodingKeys.listId)
        static let isCompleted = Column(CodingKeys.isCompleted)
        static let completedAt = Column(CodingKeys.completedAt)
    }
}
