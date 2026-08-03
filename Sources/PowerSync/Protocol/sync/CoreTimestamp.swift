import Foundation

/// Converts timestamps emitted by the core extension to Foundation time values.
///
/// Core sync status timestamps are encoded as microseconds since the Unix epoch.
/// `TimeInterval` expects seconds, so all sync status decoding should go through
/// this helper before exposing the value to callers.
func coreTimestampTimeInterval(_ timestamp: Int64) -> TimeInterval {
    TimeInterval(timestamp) / 1_000_000
}

func coreTimestampDate(_ timestamp: Int64) -> Date {
    Date(timeIntervalSince1970: coreTimestampTimeInterval(timestamp))
}
