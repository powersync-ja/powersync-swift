import Foundation
import Testing
import PowerSync

@Suite()
struct JsonValueTests {
    @Test func canDecode() throws {
        let decoder = JSONDecoder()
        
        try #require(try decoder.decode(JsonValue.self, from: "null".data(using: .utf8)!) == .null)
        try #require(try decoder.decode(JsonValue.self, from: "123".data(using: .utf8)!) == .int(123))
        try #require(try decoder.decode(JsonValue.self, from: "123.45".data(using: .utf8)!) == .double(123.45))
        try #require(try decoder.decode(JsonValue.self, from: "\"123\"".data(using: .utf8)!) == .string("123"))
        try #require(try decoder.decode(JsonValue.self, from: "[1,2,3]".data(using: .utf8)!) == .array([.int(1), .int(2), .int(3)]))
        try #require(try decoder.decode(JsonValue.self, from: "{\"foo\": \"bar\"}".data(using: .utf8)!) == .object(["foo": .string("bar")]))
    }
    
    @Test func canEncode() throws {
        let encoder = JSONEncoder()
        
        try #require(String(data: try encoder.encode(JsonValue.null), encoding: .utf8) == "null")
        try #require(String(data: try encoder.encode(JsonValue.int(123)), encoding: .utf8) == "123")
        try #require(String(data: try encoder.encode(JsonValue.double(123.45)), encoding: .utf8) == "123.45")
        try #require(String(data: try encoder.encode(JsonValue.string("123")), encoding: .utf8) == "\"123\"")
        try #require(String(data: try encoder.encode(JsonValue.array([.int(1), .int(2), .int(3)])), encoding: .utf8) == "[1,2,3]")
        try #require(String(data: try encoder.encode(JsonValue.object(["foo": .string("bar")])), encoding: .utf8) == "{\"foo\":\"bar\"}")
    }
}
