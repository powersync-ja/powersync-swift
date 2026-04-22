/// Loads the PowerSync SQLite core extension.
/// 
/// In older versions of the Swift SDK, this used to return a file path that would have to
/// be loaded with `sqlite3_load_extension`. This is no longer relevant: Calling this
/// function invokes `sqlite3_auto_extension` to load the core extension automatically.
///
/// - Returns: `nil`
/// - Throws: An error if the extension could not be registered watchOS.
public func resolvePowerSyncLoadableExtensionPath() throws(PowerSyncError) -> String? {
    try registerPowerSyncCoreExtension()
    return nil
}
