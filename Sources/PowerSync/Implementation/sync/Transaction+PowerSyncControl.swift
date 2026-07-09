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
    ///
    /// Unlike instruction-based control operations, core returns the allocated id directly as
    /// the function result.
    func powersyncNextCheckpointRequestId() throws -> Int64 {
        try get(sql: "SELECT powersync_control('next_checkpoint_request_id', NULL)", parameters: []) { cursor in
            try cursor.getInt64(index: 0)
        }
    }

    /// Reads the current local checkpoint request id without allocating a new one.
    func powersyncCurrentCheckpointRequestId() throws -> Int64? {
        try get(sql: "SELECT powersync_control('current_checkpoint_request_id', NULL)", parameters: []) { cursor in
            cursor.getInt64Optional(index: 0)
        }
    }

    /// Reads the current target checkpoint request id, or updates it when a target is supplied.
    ///
    /// Unlike instruction-based control operations, core returns the previous target directly as
    /// the function result, or `NULL` when no target is set.
    /// - Returns: The target checkpoint request id observed *before* the optional update was applied.
    func powersyncTargetCheckpointRequestId(_ targetCheckpointRequestId: Int64? = nil) throws -> Int64? {
        try get(sql: "SELECT powersync_control('target_checkpoint_request_id', ?)", parameters: [targetCheckpointRequestId]) { cursor in
            cursor.getInt64Optional(index: 0)
        }
    }

    /// Seeds the local checkpoint request counter from service state before opening the sync stream.
    ///
    /// Unlike instruction-based control operations, core returns the previous checkpoint
    /// request id directly, or `NULL` when no previous value was set.
    @discardableResult
    func powersyncSeedCheckpointRequestId(_ requestId: Int64?) throws -> Int64? {
        try get(sql: "SELECT powersync_control('seed_checkpoint_request_id', ?)", parameters: [requestId]) { cursor in
            cursor.getInt64Optional(index: 0)
        }
    }
}
