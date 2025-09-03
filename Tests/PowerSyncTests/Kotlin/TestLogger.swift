import Foundation
@testable import PowerSync

final class TestLogWriterAdapter: LogWriterProtocol,
    // The shared state is guarded by the DispatchQueue
    @unchecked Sendable
{
    private let queue = DispatchQueue(label: "TestLogWriterAdapter")

    private var logs = [String]()

    func getLogs() -> [String] {
        queue.sync {
            logs
        }
    }

    func log(severity: LogSeverity, message: String, tag: String?) {
        queue.sync {
            logs.append("\(severity): \(message) \(tag != nil ? "\(tag!)" : "")")
        }
    }
}
