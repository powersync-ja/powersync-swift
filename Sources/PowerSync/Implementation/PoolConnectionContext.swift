func poolRead<T>(_ pool: borrowing SQLiteConnectionPoolProtocol, action: @escaping @Sendable (_: any ConnectionContext) throws -> T) async throws -> T {
    let result = UnsafeSendable<T>()
    try await pool.read { lease in
        let context = NativeConnectionContext(lease)
        result.resolve(value: try action(context))
    }

    return result.inner!
}

func poolWrite<T>(_ pool: borrowing SQLiteConnectionPoolProtocol, action: @escaping @Sendable (_: any ConnectionContext) throws -> T) async throws -> T {
    let result = UnsafeSendable<T>()
    try await pool.read { lease in
        let context = NativeConnectionContext(lease)
        result.resolve(value: try action(context))
    }

    return result.inner!
}

func poolWithAll<T>(_ pool: borrowing SQLiteConnectionPoolProtocol, action: @escaping @Sendable (_ writer: any ConnectionContext, _ readers: [any ConnectionContext]) throws -> T) async throws -> T {
    let result = UnsafeSendable<T>()
    try await pool.withAllConnections { writer, readers in
        let writer = NativeConnectionContext(writer)
        let readers = readers.map { NativeConnectionContext($0) }
        
        result.resolve(value: try action(writer, readers))
    }
    return result.inner!
}

private final class UnsafeSendable<T>: @unchecked Sendable {
    var inner: T? = nil
    
    func resolve(value: T) {
        self.inner = value
    }
}
