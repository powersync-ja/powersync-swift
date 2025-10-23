import Foundation

public struct WithSessionResult<ResultType: Sendable>: Sendable {
    public let blockResult: Result<ResultType, Error>
    public let affectedTables: Set<String>
}

/// Executes an action within a SQLite database connection session and
/// returns a `WithSessionResult` containing the action result and the set of
/// tables that were affected during the session.
///
/// The raw SQLite connection is only available in some niche scenarios. This helper is
/// intended for internal use.
///
/// - The provided `action` is executed inside a database session.
/// - Any success or failure from the `action` is captured in
///   `WithSessionResult.blockResult`.
/// - The set of updated table names is returned in
///   `WithSessionResult.affectedTables`.
///
/// Example usage:
/// ```swift
/// let result = try withSession(db: database) {
///     // perform database work and return a value
///     try someOperation()
/// }
///
/// switch result.blockResult {
/// case .success(let value):
///     print("Operation succeeded with: \(value)")
/// case .failure(let error):
///     print("Operation failed: \(error)")
/// }
///
/// print("Updated tables: \(result.affectedTables)")
/// ```
///
/// - Parameters:
///   - db: The raw SQLite connection pointer used to open the session.
///   - action: The operation to execute within the session. Its return value is
///     propagated into `WithSessionResult.blockResult` on success.
/// - Returns: A `WithSessionResult` containing the action's result and the set
///   of affected table names.
/// - Throws: Any error thrown while establishing the session or executing the
///   provided `action`.
public func withSession<ReturnType>(
    db: OpaquePointer,
    action: @escaping () throws -> ReturnType
) throws -> WithSessionResult<ReturnType> {
    return try kotlinWithSession(
        db: db,
        action: action
    )
}
