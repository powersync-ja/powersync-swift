import PowerSyncKotlin

class TransactionCallback<R>: PowerSyncKotlin.ThrowableTransactionCallback {
    let callback: (ConnectionContext) throws -> R

    init(callback: @escaping (ConnectionContext) throws -> R) {
        self.callback = callback
    }

    // The Kotlin SDK does not gracefully handle exceptions thrown from Swift callbacks.
    // If a Swift callback throws an exception, it results in a `BAD ACCESS` crash.
    //
    // To prevent this, we catch the exception and return it as a `PowerSyncException`,
    // allowing Kotlin to propagate the error correctly.
    //
    // This approach is a workaround. Ideally, we should introduce an internal mechanism
    // in the Kotlin SDK to handle errors from Swift more robustly.
    //
    // Currently, we wrap the public `PowerSyncDatabase` class in Kotlin, which limits our
    // ability to handle exceptions cleanly. Instead, we should expose an internal implementation
    // from a "core" package in Kotlin that provides better control over exception handling
    // and other functionality—without modifying the public `PowerSyncDatabase` API to include
    // Swift-specific logic.
    func execute(transaction: PowerSyncKotlin.PowerSyncTransaction) throws -> Any {
        do {
            return try callback(
                KotlinConnectionContext(
                    ctx: transaction
                )
            )
        } catch {
            return PowerSyncKotlin.PowerSyncException(
                message: error.localizedDescription,
                cause: PowerSyncKotlin.KotlinThrowable(message: error.localizedDescription)
            )
        }
    }
}
