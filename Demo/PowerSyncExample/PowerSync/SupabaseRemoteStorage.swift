import Foundation
import PowerSync
import Supabase

class SupabaseRemoteStorage: RemoteStorageAdapter {
    let storage: Supabase.StorageFileApi

    init(storage: Supabase.StorageFileApi) {
        self.storage = storage
    }

    func uploadFile(fileData: Data, attachment: PowerSync.Attachment) async throws {
        try await storage.upload(attachment.filename, data: fileData)
    }

    func downloadFile(attachment: PowerSync.Attachment) async throws -> Data {
        try await storage.download(path: attachment.filename)
    }

    func deleteFile(attachment: PowerSync.Attachment) async throws {
        _ = try await storage.remove(paths: [attachment.filename])
    }
}
