import Foundation
import SwiftData

enum Mood: String, Codable, Sendable {
    case sunny
    case stormy
}

enum Level: Int, Codable, Sendable {
    case low = 1
    case high = 9
}

struct Geo: Codable, Equatable, Sendable {
    var lat: Double
    var lon: Double
}

/// Exercises every attribute type the store supports (spec §6).
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class TypeMix {
    var id: String
    var text: String
    var integer: Int
    var integer64: Int64
    var integer32: Int32
    var flag: Bool
    var fraction: Double
    var fraction32: Float
    var stamp: Date
    var payload: Data
    var token: UUID
    var mood: Mood
    var level: Level
    var geo: Geo
    var subtitle: String?
    var optionalNumber: Int?
    var optionalStamp: Date?
    var optionalPayload: Data?

    init(
        id: String,
        text: String,
        integer: Int,
        integer64: Int64,
        integer32: Int32,
        flag: Bool,
        fraction: Double,
        fraction32: Float,
        stamp: Date,
        payload: Data,
        token: UUID,
        mood: Mood,
        level: Level,
        geo: Geo,
        subtitle: String?,
        optionalNumber: Int?,
        optionalStamp: Date?,
        optionalPayload: Data?
    ) {
        self.id = id
        self.text = text
        self.integer = integer
        self.integer64 = integer64
        self.integer32 = integer32
        self.flag = flag
        self.fraction = fraction
        self.fraction32 = fraction32
        self.stamp = stamp
        self.payload = payload
        self.token = token
        self.mood = mood
        self.level = level
        self.geo = geo
        self.subtitle = subtitle
        self.optionalNumber = optionalNumber
        self.optionalStamp = optionalStamp
        self.optionalPayload = optionalPayload
    }
}
