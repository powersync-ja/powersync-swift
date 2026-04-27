import Foundation

func sleepForSeconds(seconds: TimeInterval) async throws {
    if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
        try await Task.sleep(for: .seconds(seconds))
    } else {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
