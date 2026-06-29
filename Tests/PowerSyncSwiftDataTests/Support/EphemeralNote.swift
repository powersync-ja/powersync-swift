import Foundation
import SwiftData

/// A model with an ephemeral (transient) attribute that must never reach PowerSync.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class EphemeralNote {
    var id: String
    var title: String
    @Attribute(.ephemeral)
    var draft: String = ""

    init(id: String, title: String, draft: String = "") {
        self.id = id
        self.title = title
        self.draft = draft
    }
}
