import Foundation
import PowerSync
@testable import PowerSyncSwiftData
import SwiftData
import Testing

/// Round-trips every supported attribute type (spec type table): scalars, Date, Data,
/// UUID, raw-representable enums, Codable values, and optionals flipping nil <-> value.
@Suite("Attribute coercion")
struct AttributeCoercionTests {
    @available(iOS 18, macOS 15, watchOS 11, tvOS 18, *)
    @Test func allSupportedAttributeTypesRoundTrip() async throws {
        let database = try await TestDatabases.makeTypeMixDatabase()
        let configuration = PowerSyncDataStoreConfiguration(name: "coercion-types", database: database)
        let container = try ModelContainer(
            for: SwiftData.Schema([TypeMix.self]),
            configurations: [configuration]
        )

        let id = UUID().uuidString.lowercased()
        let stamp = Date(timeIntervalSince1970: 1_760_000_000.25)
        let payload = Data([0x01, 0x02, 0xFE, 0xFF])
        let token = UUID()
        let geo = Geo(lat: 43.263, lon: -2.935)

        let context = ModelContext(container)
        context.insert(TypeMix(
            id: id,
            text: "txt",
            integer: -42,
            integer64: 9_000_000_000,
            integer32: 123_456,
            flag: true,
            fraction: 3.14159,
            fraction32: 2.5,
            stamp: stamp,
            payload: payload,
            token: token,
            mood: .stormy,
            level: .high,
            geo: geo,
            subtitle: "sub",
            optionalNumber: nil,
            optionalStamp: nil,
            optionalPayload: nil
        ))
        try context.save()

        let secondContext = ModelContext(container)
        let fetched = try secondContext.fetch(FetchDescriptor<TypeMix>())
        #expect(fetched.count == 1)
        let m = try #require(fetched.first)
        #expect(m.id == id)
        #expect(m.text == "txt")
        #expect(m.integer == -42)
        #expect(m.integer64 == 9_000_000_000)
        #expect(m.integer32 == 123_456)
        #expect(m.flag == true)
        #expect(m.fraction == 3.14159)
        #expect(m.fraction32 == 2.5)
        #expect(abs(m.stamp.timeIntervalSince(stamp)) < 0.001)
        #expect(m.payload == payload)
        #expect(m.token == token)
        #expect(m.mood == .stormy)
        #expect(m.level == .high)
        #expect(m.geo == geo)
        #expect(m.subtitle == "sub")
        #expect(m.optionalNumber == nil)
        #expect(m.optionalStamp == nil)
        #expect(m.optionalPayload == nil)

        // Flip the optionals through an update: set the nil ones, clear the set one.
        m.subtitle = nil
        m.optionalNumber = 7
        m.optionalStamp = stamp
        m.optionalPayload = payload
        try secondContext.save()

        let refetched = try ModelContext(container).fetch(FetchDescriptor<TypeMix>())
        let m2 = try #require(refetched.first)
        #expect(m2.subtitle == nil)
        #expect(m2.optionalNumber == 7)
        #expect(abs((m2.optionalStamp ?? .distantPast).timeIntervalSince(stamp)) < 0.001)
        #expect(m2.optionalPayload == payload)

        try await database.close()
    }
}
