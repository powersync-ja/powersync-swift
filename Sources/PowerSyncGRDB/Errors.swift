/// Errors thrown by the PowerSyncGRDB integration layer.
///
/// These errors represent issues encountered when bridging GRDB and PowerSync,
/// such as missing extensions, failed extension loads, or unavailable connections.
public enum PowerSyncGRDBError: Error {
    /// The PowerSync SQLite core bundle could not be found.
    case coreBundleNotFound

    /// Failed to load the PowerSync SQLite extension, with an associated error message.
    case extensionLoadFailed(String)

    /// An unknown error occurred while loading the PowerSync SQLite extension.
    case unknownExtensionLoadError

    /// The underlying SQLite connection could not be obtained from GRDB.
    case connectionUnavailable
}
