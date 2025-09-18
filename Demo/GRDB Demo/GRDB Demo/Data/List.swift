import GRDB
import PowerSync

/// PowerSync client side schema
let listsTable = Table(
    name: "lists",
    columns: [
        .text("name"),
        .text("owner_id")
    ]
)

struct List: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var ownerId: String

    static var databaseTableName = "lists"

    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownerId = "owner_id"
    }
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let ownerId = Column(CodingKeys.ownerId)
    }

    static let todos = hasMany(
        Todo.self, key: "todos",
        using: ForeignKey([Todo.Columns.listId], to: [Columns.id])
    )
}

/// Result for displaying lists in the main view
struct ListWithTodoCounts: Decodable, Hashable, Identifiable, FetchableRecord {
    var id: String
    var name: String
    var pendingCount: Int
}
