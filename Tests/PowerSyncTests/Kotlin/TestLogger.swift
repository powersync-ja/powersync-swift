@testable import PowerSync


class TestLogWriterAdapter: LogWriterProtocol {
    var logs = [String]()
    
    func log(severity: LogSeverity, message: String, tag: String) {
        logs.append("\(severity): \(message) (\(tag))")
    }
}

class TestLogger: DefaultLogger {
    let writer = TestLogWriterAdapter()
    
    public var logs: [String] {
            return writer.logs
    }
    
    override init(minSeverity: LogSeverity = .debug) {
        super.init(minSeverity: minSeverity)
        setWriters([writer])
    }
}
