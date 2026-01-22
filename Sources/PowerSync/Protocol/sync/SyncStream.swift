import Foundation

/// Information uniquely identifying a sync stream that can be subscribed to.
public protocol SyncStreamDescription: Sendable {
    /// The name of the sync stream as it appeaers in the stream definition for the PowerSync service.
    var name: String { get }
    /// The parameters used to subscribe to the stream, if any.
    ///
    /// The same stream can be subscribed to multiple times with different parameters.
    var parameters: JsonParam? { get }
}

/// A handle to a ``SyncStreamDescription`` that allows subscribing to the stream.
///
/// To obtain an instance of ``SyncStream``, call ``PowerSyncDatabase/syncStream``.
public protocol SyncStream: SyncStreamDescription {
    /// Creates a new subscription on this stream.
    ///
    /// As long as a subscription is active on the stream, the sync client will request it from the sync service.
    ///
    /// This call is generally quite cheap and can be issued frequently, e.g. when a view needing data from the stream is activated.
    func subscribe(ttl: TimeInterval?, priority: BucketPriority?) async throws -> any SyncStreamSubscription
    
    /// Unsubscribes all existing subscriptions on this stream.
    ///
    /// This is a potentially unsafe method since it interferes with other subscriptions. A better option is to call
    /// ``SyncStreamSubscription/unsubscribe``.
    func unsubscribeAll() async throws
}

extension SyncStream {
    
    public func subscribe() async throws -> any SyncStreamSubscription {
        return try await subscribe(ttl: nil, priority: nil)
    }
}

/// A ``SyncStream`` that has an active subscription.
public protocol SyncStreamSubscription: SyncStreamDescription {
    /// An asynchronous function that completes once data on this stream has been synced.
    func waitForFirstSync() async throws
    /// Removes this subscription.
    ///
    /// Once all ``SyncStreamSubscription``s for a ``SyncStream`` have been unsubscribed, the `ttl`
    /// for that stream thats running. When it expires without subscribing again, the stream will be evicted.
    func unsubscribe() async throws
}

/// Information about a subscribed sync stream.
///
/// This includes the  ``SyncStreamDescription`` along with information about the current sync status.
public struct SyncSubscriptionDescription: SyncStreamDescription {
    public let name: String
    public let parameters: JsonParam?
    /// Whether this stream is active, meaning that the subscription has been acknowledged by the sync service.
    public let active: Bool
    /// Whether this stream subscription is included by default, regardless of whether the stream has explicitly
    /// been subscribed to or not.
    ///
    /// Default streams are created by applying `auto_subscribe: true` in their definition on the sync service.
    ///
    /// It's possible for both ``SyncSubscriptionDescription/isDefault`` and
    /// ``SyncSubscriptionDescription/hasExplicitSubscription`` to be true at the same time. This
    /// happens when a default stream was subscribed to explicitly.
    public let isDefault: Bool
    /// Whether this stream has been subscribed to explicitly.
    ///
    /// It's possible for both ``SyncSubscriptionDescription/isDefault`` and
    /// ``SyncSubscriptionDescription/hasExplicitSubscription`` to be true at the same time. This
    /// happens when a default stream was subscribed to explicitly.
    public let hasExplicitSubscription: Bool
    /// For sync streams that have a time-to-live, the current time at which the stream would expire if not subscribed to
    /// again.
    public let expiresAt: TimeInterval?
    /// If ``SyncSubscriptionDescription/hasSynced`` is true, the last time data from this stream has been synced.
    public let lastSyncedAt: TimeInterval?
    
    /// Whether this stream has been synced at least once.
    public var hasSynced: Bool {
        get {
            return self.expiresAt != nil
        }
    }
}
