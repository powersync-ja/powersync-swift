import Foundation
import PowerSync

struct ListContent: Identifiable, Hashable, Decodable {
    let id: String
    var name: String
    var createdAt: String
    var ownerId: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case ownerId = "owner_id"
    }
}

struct NewListContent: Encodable {
    var name: String
    var ownerId: String
    var createdAt: String
}
