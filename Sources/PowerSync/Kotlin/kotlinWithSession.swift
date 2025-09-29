import PowerSyncKotlin

func kotlinWithSession<ReturnType>(
    db: OpaquePointer,
    action: @escaping () throws -> ReturnType,
    onComplete: @escaping (Result<ReturnType, Error>, Set<String>) -> Void,
) throws {
    try withSession(
        db: UnsafeMutableRawPointer(db),
        onComplete: { powerSyncResult, updates in
            let result: Result<ReturnType, Error>
            switch powerSyncResult {
            case let success as PowerSyncResult.Success:
                do {
                    let casted = try safeCast(success.value, to: ReturnType.self)
                    result = .success(casted)
                } catch {
                    result = .failure(error)
                }

            case let failure as PowerSyncResult.Failure:
                result = .failure(failure.exception.asError())

            default:
                result = .failure(PowerSyncError.operationFailed(message: "Unknown error encountered when processing session"))
            }
            onComplete(result, updates)
        },
        block: {
            do {
                return try PowerSyncResult.Success(value: action())
            } catch {
                return PowerSyncResult.Failure(exception: error.toPowerSyncError())
            }
        }
    )
}
