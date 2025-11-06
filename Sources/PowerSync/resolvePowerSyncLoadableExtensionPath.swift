/// Resolves the PowerSync SQLite extension path.
///
/// This function returns the file system path to the PowerSync SQLite extension library.
/// For use with extension loading APIs or SQLite queries.
///
/// ## Platform Behavior
///
/// ### watchOS
/// On watchOS, the extension needs to be loaded statically. This function returns `nil`
/// on watchOS because the extension is statically linked and doesn't require a path.
/// Calling this function will auto-register the extension in watchOS. The static
/// initialization ensures the extension is available without requiring dynamic loading.
///
/// ### Other Platforms
/// In other environments (iOS, macOS, tvOS, etc.), the extension needs to be loaded
/// dynamically using the path returned by this function. You'll need to:
/// 1. Enable extension loading on your SQLite connection
/// 2. Load the extension using the returned path
///
/// ## Example Usage
///
/// ### Loading with SQLite API
/// ```swift
/// guard let extensionPath = try resolvePowerSyncLoadableExtensionPath() else {
///     // On watchOS, extension is statically loaded, no path needed
///     return
/// }
///
/// // Enable extension loading
/// sqlite3_enable_load_extension(db, 1)
///
/// // Load the extension
/// var errorMsg: UnsafeMutablePointer<Int8>?
/// let result = sqlite3_load_extension(
///     db,
///     extensionPath,
///     "sqlite3_powersync_init",
///     &errorMsg
/// )
/// if result != SQLITE_OK {
///     // Handle error
/// }
/// ```
///
/// ### Loading with SQL Query
/// ```swift
/// guard let extensionPath = try resolvePowerSyncLoadableExtensionPath() else {
///     // On watchOS, extension is statically loaded, no path needed
///     return
/// }
/// let escapedPath = extensionPath.replacingOccurrences(of: "'", with: "''")
/// let query = "SELECT load_extension('\(escapedPath)', 'sqlite3_powersync_init')"
/// try db.execute(sql: query)
/// ```
///
/// - Returns: The file system path to the PowerSync SQLite extension, or `nil` on watchOS
///   (where the extension is statically loaded and doesn't require a path)
/// - Throws: An error if the extension path cannot be resolved on platforms that require it or
///   if the extension could not be registered on watchOS.
public func resolvePowerSyncLoadableExtensionPath() throws -> String? {
    return try kotlinResolvePowerSyncLoadableExtensionPath()
}
