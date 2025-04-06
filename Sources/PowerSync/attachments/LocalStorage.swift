import Foundation

/**
 * Error type for PowerSync operations
 */
public enum PowerSyncError: Error {
    case generalError(String)
    case fileNotFound(String)
    case ioError(Error)
    case invalidPath(String)
    case attachmentError(String)
}

/**
 * Storage adapter for local storage
 */
public protocol LocalStorageAdapter {
    /**
     * Saves data to a file at the specified path.
     * @returns the bytesize of the file
     */
    func saveFile(
        filePath: String,
        data: Data
    ) async throws -> Int64
    
    /**
     * Reads a file from the specified path.
     */
    func readFile(
        filePath: String,
        mediaType: String?
    ) async throws -> Data
    
    /**
     * Deletes a file at the specified path.
     */
    func deleteFile(filePath: String) async throws
    
    /**
     * Checks if a file exists at the specified path.
     */
    func fileExists(filePath: String) async throws -> Bool
    
    /**
     * Creates a directory at the specified path.
     */
    func makeDir(path: String) async throws
    
    /**
     * Removes a directory at the specified path.
     */
    func rmDir(path: String) async throws
    
    /**
     * Copies a file from source path to target path.
     */
    func copyFile(
        sourcePath: String,
        targetPath: String
    ) async throws
}

/**
 * Extension providing default parameter for readFile
 */
public extension LocalStorageAdapter {
    func readFile(filePath: String) async throws -> Data {
        return try await readFile(filePath: filePath, mediaType: nil)
    }
}

