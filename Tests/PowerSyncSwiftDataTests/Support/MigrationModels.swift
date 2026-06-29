import Foundation
import SwiftData

/// Simulates a model that gained a required-with-default property after rows existed.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Migrated {
    var id: String
    var name: String
    var rating: Int = 5

    init(id: String, name: String, rating: Int = 5) {
        self.id = id
        self.name = name
        self.rating = rating
    }
}

/// A model with a required property and no default, to pin the failure mode when stored
/// rows predate the property.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Strict {
    var id: String
    var score: Int

    init(id: String, score: Int) {
        self.id = id
        self.score = score
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
enum NoopMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [] }
    static var stages: [MigrationStage] { [] }
}
