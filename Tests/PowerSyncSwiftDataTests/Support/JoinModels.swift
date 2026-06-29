import Foundation
import SwiftData

/// Self-referential to-one used to exercise a true reference cycle in one save.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Twin {
    var id: String
    var name: String
    var partner: Twin?

    init(id: String, name: String, partner: Twin? = nil) {
        self.id = id
        self.name = name
        self.partner = partner
    }
}

/// Many-to-many modeled the supported way: an explicit join @Model with two to-ones.
@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Student {
    var id: String
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \Enrollment.student)
    var enrollments: [Enrollment] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Course {
    var id: String
    var title: String
    @Relationship(deleteRule: .cascade, inverse: \Enrollment.course)
    var enrollments: [Enrollment] = []

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

@available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
@Model
final class Enrollment {
    var id: String
    var student: Student?
    var course: Course?

    init(id: String, student: Student? = nil, course: Course? = nil) {
        self.id = id
        self.student = student
        self.course = course
    }
}
