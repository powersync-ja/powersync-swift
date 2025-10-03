import Foundation

/// Executes an action within a SQLite database connection session and handles its result.
///
/// The Raw SQLite connection is only available in some niche scenarios.
///
/// - Executes the provided action in a SQLite session
/// - Handles success/failure results
/// - Tracks table updates during execution
/// - Provides type-safe result handling
///
/// Example usage:
/// ```swift
/// try withSession(db: database) {
///     return try someOperation()
/// } onComplete: { result, updates in
///     switch result {
///     case .success(let value):
///         print("Operation succeeded with: \(value)")
///     case .failure(let error):
///         print("Operation failed: \(error)")
///     }
/// }
/// ```
///
/// - Parameters:
///   - db: The database connection pointer
///   - action: The operation to execute within the session
///   - onComplete: Callback that receives the operation result and set of updated tables
/// - Throws: Errors from session initialization or execution
public func withSession<ReturnType>(
    db: OpaquePointer,
    action: @escaping () throws -> ReturnType,
    onComplete: @escaping (Result<ReturnType, Error>, Set<String>) -> Void,
) throws {
    return try kotlinWithSession(
        db: db,
        action: action,
        onComplete: onComplete,
    )
}
