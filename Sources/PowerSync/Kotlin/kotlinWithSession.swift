import PowerSyncKotlin

func kotlinWithSession<ReturnType>(
    db: OpaquePointer,
    action: @escaping () throws -> ReturnType,
) throws -> WithSessionResult<ReturnType> {
    let baseResult = try withSession(
        db: UnsafeMutableRawPointer(db),
        block: {
            do {
                return try PowerSyncResult.Success(value: action())
            } catch {
                return PowerSyncResult.Failure(exception: error.toPowerSyncError())
            }
        }
    )

    var outputResult: Result<ReturnType, Error>
    switch baseResult.blockResult {
    case let success as PowerSyncResult.Success:
        do {
            let casted = try safeCast(success.value, to: ReturnType.self)
            outputResult = .success(casted)
        } catch {
            outputResult = .failure(error)
        }

    case let failure as PowerSyncResult.Failure:
        outputResult = .failure(failure.exception.asError())

    default:
        outputResult = .failure(PowerSyncError.operationFailed(message: "Unknown error encountered when processing session"))
    }

    return WithSessionResult(
        blockResult: outputResult,
        affectedTables: baseResult.affectedTables
    )
}
