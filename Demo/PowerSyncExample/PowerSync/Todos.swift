import Foundation
import PowerSync

struct Todo: Identifiable, Hashable, Decodable {
    let id: String
    var listId: String
    var photoId: String?
    var description: String
    var isComplete: Bool = false
    var createdAt: String?
    var completedAt: String?
    var createdBy: String?
    var completedBy: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case listId = "list_id"
        case isComplete = "completed"
        case description
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case createdBy = "created_by"
        case completedBy = "completed_by"
        case photoId = "photo_id"
        
    }
}

struct NewTodo: Encodable {
    var listId: String
    var isComplete: Bool = false
    var description: String
    var createdAt: String?
    var completedAt: String?
    var createdBy: String?
    var completedBy: String?
    var photoId: String?
}
