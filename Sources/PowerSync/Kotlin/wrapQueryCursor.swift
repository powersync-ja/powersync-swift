import PowerSyncKotlin

/// The Kotlin SDK does not gracefully handle exceptions thrown from Swift callbacks.
/// If a Swift callback throws an exception, it results in a `BAD ACCESS` crash.
///
/// This approach is a workaround. Ideally, we should introduce an internal mechanism
/// in the Kotlin SDK to handle errors from Swift more robustly.
///
/// This hoists any exceptions thrown in a cursor mapper in order for the error to propagate correctly.
///
/// Currently, we wrap the public `PowerSyncDatabase` class in Kotlin, which limits our
/// ability to handle exceptions cleanly. Instead, we should expose an internal implementation
/// from a "core" package in Kotlin that provides better control over exception handling
/// and other functionality—without modifying the public `PowerSyncDatabase` API to include
/// Swift-specific logic.
func wrapQueryCursor<RowType, ReturnType>(
    mapper: @Sendable @escaping (SqlCursor) throws -> RowType,
    //    The Kotlin APIs return the results as Any, we can explicitly cast internally
    executor: @Sendable @escaping (_ wrappedMapper: @escaping (PowerSyncKotlin.SqlCursor) -> RowType?) throws -> ReturnType
) throws -> ReturnType {
    var mapperException: Error?

    // Wrapped version of the mapper that catches exceptions and sets `mapperException`
    // In the case of an exception this will return an empty result.
    let wrappedMapper: (PowerSyncKotlin.SqlCursor) -> RowType? = { cursor in
        do {
            return try mapper(KotlinSqlCursor(
                base: cursor
            ))
        } catch {
            // Store the error in order to propagate it
            mapperException = error
            // Return nothing here. Kotlin should handle this as an empty object/row
            return nil
        }
    }

    let executionResult = try executor(wrappedMapper)

    if let mapperException {
        // Allow propagating the error
        throw mapperException
    }

    return executionResult
}

func wrapQueryCursorTyped<RowType: Sendable, ReturnType: Sendable>(
    mapper: @Sendable @escaping (SqlCursor) throws -> RowType,
    //    The Kotlin APIs return the results as Any, we can explicitly cast internally
    executor: @Sendable @escaping (_ wrappedMapper: @escaping (PowerSyncKotlin.SqlCursor) -> Any?) throws -> Any?,
    resultType: ReturnType.Type
) throws -> ReturnType {
    return try safeCast(
        wrapQueryCursor(
            mapper: mapper,
            executor: executor
        ), to:
        resultType
    )
}

/// Throws a `PowerSyncException` using a helper provided by the Kotlin SDK.
/// We can't directly throw Kotlin `PowerSyncException`s from Swift, but we can delegate the throwing
/// to the Kotlin implementation.
/// Our Kotlin SDK methods handle thrown Kotlin `PowerSyncException` correctly.
/// The flow of events is as follows
///     Swift code calls `throwKotlinPowerSyncError`
///          This method calls the Kotlin helper `throwPowerSyncException` which is annotated as being able to throw `PowerSyncException`
///             The Kotlin helper throws the provided `PowerSyncException`. Since the method is annotated the exception propagates back to Swift, but in a form which can propagate back
///             to any calling Kotlin stack.
/// This only works for SKIEE methods which have an associated completion handler which handles annotated errors.
/// This seems to only apply for Kotlin suspending function bindings.
func throwKotlinPowerSyncError(message: String, cause: String? = nil) throws {
    try throwPowerSyncException(
        exception: PowerSyncKotlin.PowerSyncException(
            message: message,
            cause: PowerSyncKotlin.KotlinThrowable(
                message: cause ?? message
            )
        )
    )
}
