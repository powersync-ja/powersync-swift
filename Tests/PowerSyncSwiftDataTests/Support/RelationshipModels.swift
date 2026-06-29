import Foundation
import SwiftData

/// Parent side of a classic to-one/to-many pair.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Playlist {
    var id: String
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \Song.playlist)
    var songs: [Song] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Song {
    var id: String
    var title: String
    var playlist: Playlist?

    init(id: String, title: String, playlist: Playlist? = nil) {
        self.id = id
        self.title = title
        self.playlist = playlist
    }
}

/// A many-to-many pair WITHOUT an explicit join model — unsupported by design (the join
/// table must exist as a synced PowerSync table anyway).
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Conference {
    var id: String
    var name: String
    @Relationship(inverse: \Speaker.conferences)
    var speakers: [Speaker] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Speaker {
    var id: String
    var name: String
    var conferences: [Conference] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
