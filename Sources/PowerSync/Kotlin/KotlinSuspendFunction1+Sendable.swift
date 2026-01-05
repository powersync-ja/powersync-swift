import PowerSyncKotlin

// Since SendableSuspendFunction1 is a protocol from PowerSyncKotlin, we need to use a wrapper class
// to make it Sendable since we can't extend the protocol directly with Sendable.
final class SendableSuspendFunction1: @unchecked Sendable {
    private let wrapped: any PowerSyncKotlin.KotlinSuspendFunction1

    init(_ function: any PowerSyncKotlin.KotlinSuspendFunction1) {
        wrapped = function
    }

    func invoke(p1: Any?) async throws -> Any? {
        return try await wrapped.invoke(p1: p1)
    }
}
