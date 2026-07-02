enum CoreLogSeverity: String, Decodable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
}

/// An instruction sent from the core extension to the Swift sync client.
enum Instruction {
    case logLine(severity: CoreLogSeverity, line: String)
    case updateSyncStatus(status: CoreDownloadSyncStatus)
    case establishSyncStream(request: JsonParam, lastCheckpointRequestId: Int64?)
    case fetchCredentials(didExpire: Bool)
    case checkpointRequestId(requestId: Int64)
    case localTargetOp(targetOp: Int64?)
    case closeSyncStream(hideDisconnect: Bool)
    case flushFileSystem
    case didCompleteSync
    case handleDiagnostics
}

extension Instruction: Decodable {
    enum CodingKeys: String, CodingKey {
        case logLine = "LogLine"
        case updateSyncStatus = "UpdateSyncStatus"
        case establishSyncStream = "EstablishSyncStream"
        case fetchCredentials = "FetchCredentials"
        case checkpointRequestId = "CheckpointRequestId"
        case localTargetOp = "LocalTargetOp"
        case closeSyncStream = "CloseSyncStream"
        case flushFileSystem = "FlushFileSystem"
        case didCompleteSync = "DidCompleteSync"
        case handleDiagnostics = "HandleDiagnostics"
    }
    
    enum LogLineCodingKeys: CodingKey {
        case severity
        case line
    }
    
    enum UpdateSyncStatusCodingKeys: CodingKey {
        case status
    }
    
    enum EstablishSyncStreamCodingKeys: String, CodingKey {
        case request
        case lastCheckpointRequestId = "last_checkpoint_request_id"
    }
    
    enum FetchCredentialsCodingKeys: String, CodingKey {
        case didExpire = "did_expire"
    }

    enum CheckpointRequestIdCodingKeys: String, CodingKey {
        case requestId = "request_id"
    }

    enum LocalTargetOpCodingKeys: String, CodingKey {
        case targetOp = "target_op"
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
            self = Instruction.establishSyncStream(
                request: try nestedContainer.decode(JsonParam.self, forKey: Instruction.EstablishSyncStreamCodingKeys.request),
                lastCheckpointRequestId: try nestedContainer.decodeIfPresent(Int64.self, forKey: Instruction.EstablishSyncStreamCodingKeys.lastCheckpointRequestId)
            )
        case .fetchCredentials:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.FetchCredentialsCodingKeys.self, forKey: .fetchCredentials)
            self = Instruction.fetchCredentials(didExpire: try nestedContainer.decode(Bool.self, forKey: Instruction.FetchCredentialsCodingKeys.didExpire))
        case .checkpointRequestId:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.CheckpointRequestIdCodingKeys.self, forKey: .checkpointRequestId)
            self = Instruction.checkpointRequestId(requestId: try nestedContainer.decode(Int64.self, forKey: Instruction.CheckpointRequestIdCodingKeys.requestId))
        case .localTargetOp:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.LocalTargetOpCodingKeys.self, forKey: .localTargetOp)
            self = Instruction.localTargetOp(targetOp: try nestedContainer.decodeIfPresent(Int64.self, forKey: Instruction.LocalTargetOpCodingKeys.targetOp))
        case .closeSyncStream:
            let nestedContainer = try container.nestedContainer(keyedBy: Instruction.CloseSyncStreamCodingKeys.self, forKey: .closeSyncStream)
            self = Instruction.closeSyncStream(hideDisconnect: try nestedContainer.decode(Bool.self, forKey: Instruction.CloseSyncStreamCodingKeys.hideDisconnect))
        case .flushFileSystem:
            self = Instruction.flushFileSystem
        case .didCompleteSync:
            self = Instruction.didCompleteSync
        case .handleDiagnostics:
            self = Instruction.handleDiagnostics
        }
    }
}
