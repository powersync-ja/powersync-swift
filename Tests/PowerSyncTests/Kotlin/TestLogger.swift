@testable import PowerSync


class TestLogWriterAdapter: LogWriterProtocol {
    var logs = [String]()
    
    func log(severity: LogSeverity, message: String, tag: String) {
        logs.append("\(severity): \(message) (\(tag))")
    }
}

