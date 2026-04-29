enum CoreLogSeverity: String, Decodable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
}

/// An instruction sent from the core extension to the Swift sync client.
enum Instruction {
    case logLine(severity: CoreLogSeverity, line: String)
    case updateSyncStatus(status: CoreDownloadSyncStatus)
    case establishSyncStream(request: JsonParam)
    case fetchCredentials(didExpire: Bool)
    case closeSyncStream(hideDisconnect: Bool)
    case flushFileSystem
    case didCompleteSync
}

extension Instruction: Decodable {
    enum CodingKeys: String, CodingKey {
        case logLine = "LogLine"
        case updateSyncStatus = "UpdateSyncStatus"
        case establishSyncStream = "EstablishSyncStream"
        case fetchCredentials = "FetchCredentials"
        case closeSyncStream = "CloseSyncStream"
        case flushFileSystem = "FlushFileSystem"
        case didCompleteSync = "DidCompleteSync"
    }
    
    enum LogLineCodingKeys: CodingKey {
        case severity
        case line
    }
    
    enum UpdateSyncStatusCodingKeys: CodingKey {
        case status
    }
    
    enum EstablishSyncStreamCodingKeys: CodingKey {
        case request
    }
    
    enum FetchCredentialsCodingKeys: String, CodingKey {
        case didExpire = "did_expire"
    }
    
    enum CloseSyncStreamCodingKeys: String, CodingKey {
        case hideDisconnect = "hide_disconnect"
    }
    
    enum FlushFileSystemCodingKeys: CodingKey {
    }
    
    enum DidCompleteSyncCodingKeys: CodingKey {
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var allKeys = ArraySlice(container.allKeys)
        guard let onlyKey = allKeys.popFirst(), allKeys.isEmpty else {
            throw DecodingError.typeMismatch(
                Instruction.self,
                DecodingError.Context.init(codingPath: container.codingPath, debugDescription: "Invalid number of keys found, expected one.", underlyingError: nil)
            )
        }

        switch onlyKey {
        case .logLine:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.LogLineCodingKeys.self, forKey: .logLine)
            self = Instruction.logLine(
                severity: try nestedContainer.decode(CoreLogSeverity.self, forKey: Instruction.LogLineCodingKeys.severity),
                line: try nestedContainer.decode(String.self, forKey: Instruction.LogLineCodingKeys.line)
            )
        case .updateSyncStatus:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.UpdateSyncStatusCodingKeys.self, forKey: .updateSyncStatus)
            self = Instruction.updateSyncStatus(status: try nestedContainer.decode(CoreDownloadSyncStatus.self, forKey: Instruction.UpdateSyncStatusCodingKeys.status))
        case .establishSyncStream:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.EstablishSyncStreamCodingKeys.self, forKey: .establishSyncStream)
            self = Instruction.establishSyncStream(request: try nestedContainer.decode(JsonParam.self, forKey: Instruction.EstablishSyncStreamCodingKeys.request))
        case .fetchCredentials:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.FetchCredentialsCodingKeys.self, forKey: .fetchCredentials)
            self = Instruction.fetchCredentials(didExpire: try nestedContainer.decode(Bool.self, forKey: Instruction.FetchCredentialsCodingKeys.didExpire))
        case .closeSyncStream:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.CloseSyncStreamCodingKeys.self, forKey: .closeSyncStream)
            self = Instruction.closeSyncStream(hideDisconnect: try nestedContainer.decode(Bool.self, forKey: Instruction.CloseSyncStreamCodingKeys.hideDisconnect))
        case .flushFileSystem:
            self = Instruction.flushFileSystem
        case .didCompleteSync:
            self = Instruction.didCompleteSync
        }
    }
}
