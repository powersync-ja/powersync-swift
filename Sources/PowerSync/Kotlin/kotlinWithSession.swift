import PowerSyncKotlin

func kotlinWithSession<ReturnType>(
    db: OpaquePointer,
    action: @escaping () throws -> ReturnType,
) throws -> WithSessionResult<ReturnType> {
    var innerResult: ReturnType?
    let baseResult = try withSession(
        db: UnsafeMutableRawPointer(db),
        block: {
            do {
                innerResult = try action()
                // We'll use the innerResult closure above to return the result
                return PowerSyncResult.Success(value: nil)
            } catch {
                return PowerSyncResult.Failure(exception: error.toPowerSyncError())
            }
        }
    )

    var outputResult: Result<ReturnType, Error>
    if let failure = baseResult.blockResult as? PowerSyncResult.Failure {
        outputResult = .failure(failure.exception.asError())
    } else if let result = innerResult {
        outputResult = .success(result)
    } else {
        // The return type is not nullable, so we should have a result
        outputResult = .failure(
            PowerSyncError.operationFailed(
                message: "Unknown error encountered when processing session",
            )
        )
    }

    return WithSessionResult(
        blockResult: outputResult,
        affectedTables: baseResult.affectedTables
    )
}
