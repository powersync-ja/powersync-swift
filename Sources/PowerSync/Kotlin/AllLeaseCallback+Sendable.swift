import PowerSyncKotlin

// Since AllLeaseCallback is a protocol from PowerSyncKotlin, we need to use a wrapper class
// to make it Sendable since we can't extend the protocol directly with Sendable.
final class SendableAllLeaseCallback: @unchecked Sendable {
    private let wrapped: any PowerSyncKotlin.AllLeaseCallback

    init(_ callback: any PowerSyncKotlin.AllLeaseCallback) {
        wrapped = callback
    }

    func execute(
        writeLease: PowerSyncKotlin.SwiftLeaseAdapter,
        readLeases: [PowerSyncKotlin.SwiftLeaseAdapter]
    ) throws {
        try wrapped.execute(writeLease: writeLease, readLeases: readLeases)
    }
}
