import PowerSyncKotlin

// Since LeaseCallback is a protocol from PowerSyncKotlin, we need to use a wrapper class
// to make it Sendable since we can't extend the protocol directly with Sendable.
final class SendableLeaseCallback: @unchecked Sendable {
    private let wrapped: any PowerSyncKotlin.LeaseCallback
    
    init(_ callback: any PowerSyncKotlin.LeaseCallback) {
        self.wrapped = callback
    }
    
    func execute(lease: PowerSyncKotlin.SwiftLeaseAdapter) throws {
        try wrapped.execute(lease: lease)
    }
}