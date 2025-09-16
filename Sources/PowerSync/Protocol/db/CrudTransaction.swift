import Foundation
import PowerSyncKotlin

/// A transaction of client-side changes.
public protocol CrudTransaction: Sendable {
    /// Unique transaction id.
    ///
    /// If nil, this contains a list of changes recorded without an explicit transaction associated.
    var transactionId: Int64? { get }

    /// List of client-side changes.
    var crud: [any CrudEntry] { get }

    /// Call to remove the changes from the local queue, once successfully uploaded.
    ///
    /// `writeCheckpoint` is optional.
    func complete(writeCheckpoint: String?) async throws
}

public extension CrudTransaction {
    /// Call to remove the changes from the local queue, once successfully uploaded.
    func complete() async throws {
        try await self.complete(
            writeCheckpoint: nil
        )
    }
}

/// A sequence of crud transactions in a PowerSync database.
///
/// For details, see ``PowerSyncDatabaseProtocol/getCrudTransactions()``.
public struct CrudTransactions: AsyncSequence {
    private let db: KotlinPowerSyncDatabase
    
    init(db: KotlinPowerSyncDatabase) {
        self.db = db
    }
    
    public func makeAsyncIterator() -> CrudTransactionIterator {
        let kotlinIterator = errorHandledCrudTransactions(db: self.db).makeAsyncIterator()
        return CrudTransactionIterator(inner: kotlinIterator)
    }
    
    public struct CrudTransactionIterator: AsyncIteratorProtocol {
        public typealias Element = any CrudTransaction
        
        private var inner: PowerSyncKotlin.SkieSwiftFlowIterator<PowerSyncKotlin.PowerSyncResult>
        
        internal init(inner: PowerSyncKotlin.SkieSwiftFlowIterator<PowerSyncKotlin.PowerSyncResult>) {
            self.inner = inner
        }
        
        public mutating func next() async throws -> (any CrudTransaction)? {
            if let innerTx = await self.inner.next() {
                if let success = innerTx as? PowerSyncResult.Success {
                    let tx = success.value as! PowerSyncKotlin.CrudTransaction
                    return try KotlinCrudTransaction(transaction: tx)
                } else if let failure = innerTx as? PowerSyncResult.Failure {
                    try throwPowerSyncException(exception: failure.exception)
                }
            
                fatalError("unreachable")
            } else {
                return nil
            }
        }
    }
}
