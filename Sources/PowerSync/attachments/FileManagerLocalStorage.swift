import Foundation

/**
 * Implementation of LocalStorageAdapter using FileManager
 */
public actor FileManagerStorageAdapter: LocalStorageAdapter {
    private let fileManager: FileManager

    public init(
        fileManager: FileManager? = nil
    ) {
        self.fileManager = fileManager ?? FileManager.default
    }

    public func saveFile(filePath: String, data: Data) async throws -> Int64 {
        return try await Task {
            let url = URL(fileURLWithPath: filePath)

            // Make sure the parent directory exists
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

            // Write data to file
            try data.write(to: url)

            // Return the size of the data
            return Int64(data.count)
        }.value
    }

    public func readFile(filePath: String, mediaType _: String?) async throws -> Data {
        return try await Task {
            let url = URL(fileURLWithPath: filePath)

            if !fileManager.fileExists(atPath: filePath) {
                throw PowerSyncAttachmentError.fileNotFound(filePath)
            }

            // Read data from file
            do {
                return try Data(contentsOf: url)
            } catch {
                throw PowerSyncAttachmentError.ioError(error)
            }
        }.value
    }

    public func deleteFile(filePath: String) async throws {
        try await Task {
            if fileManager.fileExists(atPath: filePath) {
                try fileManager.removeItem(atPath: filePath)
            }
        }.value
    }

    public func fileExists(filePath: String) async throws -> Bool {
        return await Task {
            fileManager.fileExists(atPath: filePath)
        }.value
    }

    public func makeDir(path: String) async throws {
        try await Task {
            try fileManager.createDirectory(atPath: path,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
        }.value
    }

    public func rmDir(path: String) async throws {
        try await Task {
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }.value
    }

    public func copyFile(sourcePath: String, targetPath: String) async throws {
        try await Task {
            if !fileManager.fileExists(atPath: sourcePath) {
                throw PowerSyncAttachmentError.fileNotFound(sourcePath)
            }

            // Ensure target directory exists
            let targetUrl = URL(fileURLWithPath: targetPath)
            try fileManager.createDirectory(at: targetUrl.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

            // If target already exists, remove it first
            if fileManager.fileExists(atPath: targetPath) {
                try fileManager.removeItem(atPath: targetPath)
            }

            try fileManager.copyItem(atPath: sourcePath, toPath: targetPath)
        }.value
    }
}
