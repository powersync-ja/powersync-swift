/// Represents a database transaction, inheriting the behavior of a connection context.
/// This protocol can be used to define operations that should be executed within the scope of a transaction.
public protocol Transaction: ConnectionContext {}
