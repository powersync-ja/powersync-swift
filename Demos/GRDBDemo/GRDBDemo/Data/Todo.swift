import Foundation
import GRDB
import PowerSync

/// PowerSync client side schema
let todosTable = Table(
    name: "todos",
    columns: [
        .text("description"),
        .text("list_id"),
        // Conversion should automatically be handled by GRDB
        .integer("completed"),
        .text("completed_at")
    ]
)

struct Todo: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var description: String
    var listId: String
    var isCompleted: Bool
    var completedAt: Date?

    static var databaseTableName = "todos"

    enum CodingKeys: String, CodingKey {
        case id
        case description
        case listId = "list_id"
        case isCompleted = "completed"
        case completedAt = "completed_at"
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let description = Column(CodingKeys.description)
        static let listId = Column(CodingKeys.listId)
        static let isCompleted = Column(CodingKeys.isCompleted)
        static let completedAt = Column(CodingKeys.completedAt)
    }
}
