import Foundation
import SwiftData

/// Flat model used by the phase 1 go/no-go gate.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Note {
    var id: String
    var title: String
    var done: Bool
    var count: Int

    init(id: String, title: String, done: Bool, count: Int) {
        self.id = id
        self.title = title
        self.done = done
        self.count = count
    }
}

/// Dedicated probe for simulating key-path reflection drift without affecting other suites.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class DriftProbe {
    var id: String
    var value: Int

    init(id: String, value: Int) {
        self.id = id
        self.value = value
    }
}

/// Like ``DriftProbe`` but with key paths provided through PUBLIC API, so it survives
/// simulated reflection drift.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class DriftSafe {
    var id: String
    var label: String

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
extension DriftSafe: PredicateCodableKeyPathProviding {
    static var predicateCodableKeyPaths: [String: any PartialKeyPath<DriftSafe> & Sendable] {
        [
            "id": \DriftSafe.id,
            "label": \DriftSafe.label,
        ]
    }
}

/// Exercises per-property column-name overrides (camelCase property, snake_case column).
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Stamp {
    var id: String
    var createdAt: Date
    var displayName: String

    init(id: String, createdAt: Date, displayName: String) {
        self.id = id
        self.createdAt = createdAt
        self.displayName = displayName
    }
}
