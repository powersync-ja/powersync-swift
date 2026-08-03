import Foundation
import PowerSync

/// A connector for the PowerSync Node.js demo backend
/// (https://github.com/powersync-ja/powersync-nodejs-backend-todolist-demo) that also handles
/// checkpoint requests itself through ``CustomCheckpointRequestConnector``.
///
/// Instead of the sync client posting checkpoint requests to the PowerSync service's
/// `/sync/checkpoint-request` endpoint, they are posted to the backend. This suits backends
/// that process uploads asynchronously (for example through a message queue): the backend can
/// create the matching checkpoint once the uploads preceding the request have been processed.
final class NodeConnector: CustomCheckpointRequestConnector {
    private let backendUrl: URL
    private let powerSyncUrl: String?
    private let userId: String
    private let logger: any LoggerProtocol

    init(backendUrl: URL, powerSyncUrl: String?, userId: String, logger: any LoggerProtocol) {
        self.backendUrl = backendUrl
        self.powerSyncUrl = powerSyncUrl
        self.userId = userId
        self.logger = logger
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        let tokenUrl = try backendEndpoint(
            "api/auth/token",
            queryItems: [URLQueryItem(name: "user_id", value: userId)]
        )
        let (data, response) = try await URLSession.shared.data(from: tokenUrl)
        try requireSuccess(response, data: data, context: "Fetch credentials")

        struct TokenResponse: Decodable {
            let token: String
            let powersync_url: String?
        }
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let endpoint = powerSyncUrl ?? tokenResponse.powersync_url else {
            throw PowerSyncError.operationFailed(
                message: "POWERSYNC_URL was not set and the backend did not return powersync_url"
            )
        }

        return PowerSyncCredentials(endpoint: endpoint, token: tokenResponse.token)
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let transaction = try await database.getNextCrudTransaction() else {
            return
        }

        let batch = transaction.crud.map { entry in
            var data: JsonParam = entry.opDataTyped ?? [:]
            data["id"] = .string(entry.id)

            return CrudUpload(
                op: entry.op.rawValue,
                table: entry.table,
                data: data
            )
        }

        try await upload(batch: batch)
        try await transaction.complete()
    }

    /// Posts a checkpoint request to the backend and returns the accepted request state.
    ///
    /// The payload mirrors what the PowerSync service's `/sync/checkpoint-request` endpoint
    /// receives. Requests are scoped to the PowerSync client ID, which the service path sends
    /// automatically but a custom connector supplies itself.
    func postCheckpointRequest(_ checkpointRequestId: Int64, clientId: String) async throws -> Int64 {
        let url = try backendEndpoint("api/data/checkpoint-request")
        logger.debug(
            "Posting checkpoint request id \(checkpointRequestId) for client \(clientId) to \(url)",
            tag: "CustomCheckpointDemo"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CheckpointRequestPayload(
            user_id: userId,
            client_id: clientId,
            checkpoint_request_id: String(checkpointRequestId)
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        try requireCheckpointSuccess(response, data: data)

        // The backend responds with the request state it accepted. This is usually the posted
        // ID, but it must return its currently recorded state when that is newer (for example
        // when the local database was cleared and the client restarted its request counter).
        do {
            let accepted = try JSONDecoder().decode(CheckpointRequestResponse.self, from: data)
            logger.debug(
                "Backend accepted checkpoint request state \(accepted.checkpointRequestId)",
                tag: "CustomCheckpointDemo"
            )
            return accepted.checkpointRequestId
        } catch let error as CheckpointRequestError {
            throw error
        } catch {
            throw CheckpointRequestError.operationFailed(
                message: "Invalid checkpoint request response.",
                underlyingError: error
            )
        }
    }

    /// Uploads one PowerSync CRUD transaction through the backend's batch endpoint.
    private func upload(batch: [CrudUpload]) async throws {
        var request = URLRequest(url: try backendEndpoint("api/data"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CrudBatchUpload(batch: batch))

        let (data, response) = try await URLSession.shared.data(for: request)
        try requireSuccess(response, data: data, context: "Batch upload")
    }

    private func backendEndpoint(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: backendUrl, resolvingAgainstBaseURL: false) else {
            throw PowerSyncError.operationFailed(message: "Invalid backend URL: \(backendUrl)")
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw PowerSyncError.operationFailed(message: "Invalid backend endpoint path: \(path)")
        }
        return url
    }

    private func requireSuccess(_ response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)
            let detail = body.map { ": \($0)" } ?? ""
            throw PowerSyncError.operationFailed(message: "\(context) failed with status code \(statusCode)\(detail)")
        }
    }

    private func requireCheckpointSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)
            let detail = body.map { ": \($0)" } ?? ""
            throw CheckpointRequestError.operationFailed(
                message: "Checkpoint request failed with status code \(statusCode)\(detail)"
            )
        }
    }
}

private struct CheckpointRequestPayload: Encodable {
    let user_id: String
    let client_id: String
    let checkpoint_request_id: String
}

private struct CrudBatchUpload: Encodable {
    let batch: [CrudUpload]
}

private struct CrudUpload: Encodable {
    let op: String
    let table: String
    let data: JsonParam
}

private struct CheckpointRequestResponse: Decodable {
    let checkpointRequestId: Int64

    enum CodingKeys: String, CodingKey {
        case checkpointRequestId = "checkpoint_request_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? container.decode(Int64.self, forKey: .checkpointRequestId) {
            checkpointRequestId = id
            return
        }

        let idString = try container.decode(String.self, forKey: .checkpointRequestId)
        guard let id = Int64(idString) else {
            throw CheckpointRequestError.operationFailed(
                message: "Backend returned a malformed checkpoint request id: \(idString)"
            )
        }
        checkpointRequestId = id
    }
}
