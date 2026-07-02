import Foundation

/// Internal convenience wrappers around `powersync_control()` operations that must run in a
/// transaction and are easier to consume as typed Swift helpers than as raw instruction JSON.
extension Transaction {
    /// Executes a sync control operation and decodes the returned core instructions.
    func powersyncControl(_ args: PowerSyncControlArguments) throws -> [Instruction] {
        let rawInstructions = try args.execute(self)
        guard let data = rawInstructions.data(using: .utf8) else {
            throw PowerSyncError.operationFailed(message: "Could not encode raw instructions")
        }

        return try StreamingSyncClient.jsonDecoder.decode([Instruction].self, from: data)
    }

    /// Allocates and persists the next local checkpoint request id.
    func powersyncNextCheckpointRequestId() throws -> Int64 {
        let instructions = try powersyncControl(.nextCheckpointRequestId)
        guard instructions.count == 1, case let .checkpointRequestId(requestId) = instructions[0] else {
            throw PowerSyncError.operationFailed(message: "Expected a CheckpointRequestId instruction")
        }

        return requestId
    }

    /// Reads the current local target op, or updates it when a target op is supplied.
    func powersyncLocalTargetOp(_ targetOp: Int64? = nil) throws -> Int64? {
        let instructions = try powersyncControl(.localTargetOp(targetOp: targetOp))
        guard instructions.count == 1, case let .localTargetOp(targetOp) = instructions[0] else {
            throw PowerSyncError.operationFailed(message: "Expected a LocalTargetOp instruction")
        }

        return targetOp
    }

    /// Seeds the local checkpoint request counter from service state before opening the sync stream.
    func powersyncSeedCheckpointRequestId(_ requestId: Int64?) throws {
        let instructions = try powersyncControl(.seedCheckpointRequestId(requestId: requestId))
        guard instructions.isEmpty else {
            throw PowerSyncError.operationFailed(message: "Expected seed_checkpoint_request_id to return no instructions")
        }
    }
}
