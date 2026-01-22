import Foundation
import PowerSyncKotlin

class KotlinStreamDescription<T: PowerSyncKotlin.SyncStreamDescription> {
    let inner: T
    let name: String
    let parameters: JsonParam?
    let kotlinParameters: [String: Any?]?
    
    init(inner: T) {
        self.inner = inner
        self.name = inner.name
        self.kotlinParameters = inner.parameters
        self.parameters = inner.parameters?.mapValues { JsonValue.fromValue(raw: $0) }
    }
}

protocol HasKotlinStreamDescription {
    associatedtype Description: PowerSyncKotlin.SyncStreamDescription
    
    var stream: KotlinStreamDescription<Description> { get }
}

extension HasKotlinStreamDescription {
    var kotlinDescription: any PowerSyncKotlin.SyncStreamDescription {
        self.stream.inner
    }
}

class KotlinSyncStream: SyncStream, HasKotlinStreamDescription,
// `PowerSyncKotlin.SyncStream` cannot be marked as Sendable, but is thread-safe.
@unchecked Sendable
{
    let stream: KotlinStreamDescription<PowerSyncKotlin.SyncStream>
    
    init(kotlinStream: PowerSyncKotlin.SyncStream) {
        self.stream = KotlinStreamDescription(inner: kotlinStream);
    }
    
    var name: String {
        stream.name
    }
    
    var parameters: JsonParam? {
        stream.parameters
    }

    func subscribe(ttl: TimeInterval?, priority: BucketPriority?) async throws -> any SyncStreamSubscription {
        let kotlinTtl: Optional<KotlinDouble> = if let ttl {
            KotlinDouble(value: ttl)
        } else {
            nil
        }
        let kotlinPriority: Optional<KotlinInt> = if let priority {
            KotlinInt(value: priority.priorityCode)
        } else {
            nil
        }

        let kotlinSubscription = try await syncStreamSubscribeSwift(
            stream: stream.inner,
            ttl: kotlinTtl,
            priority: kotlinPriority,
        );
        return KotlinSyncStreamSubscription(kotlinStream: kotlinSubscription)
    }
    
    func unsubscribeAll() async throws {
        try await stream.inner.unsubscribeAll()
    }
}

class KotlinSyncStreamSubscription: SyncStreamSubscription, HasKotlinStreamDescription,
// `PowerSyncKotlin.SyncStreamSubscription` cannot be marked as Sendable, but is thread-safe.
@unchecked Sendable
{
    let stream: KotlinStreamDescription<PowerSyncKotlin.SyncStreamSubscription>

    init(kotlinStream: PowerSyncKotlin.SyncStreamSubscription) {
        self.stream = KotlinStreamDescription(inner: kotlinStream)
    }
    
    var name: String {
        stream.name
    }
    var parameters: JsonParam? {
        stream.parameters
    }
    
    func waitForFirstSync() async throws {
        try await stream.inner.waitForFirstSync()
    }
    
    func unsubscribe() async throws {
        try await stream.inner.unsubscribe()
    }
}

func mapSyncStreamStatus(_ status: PowerSyncKotlin.SyncStreamStatus) -> SyncStreamStatus {
    let progress = status.progress.map { ProgressNumbers(source: $0) }
    let subscription = status.subscription

    return SyncStreamStatus(
        progress: progress,
        subscription: SyncSubscriptionDescription(
            name: subscription.name,
            parameters: subscription.parameters?.mapValues { JsonValue.fromValue(raw: $0) },
            active: subscription.active,
            isDefault: subscription.isDefault,
            hasExplicitSubscription: subscription.hasExplicitSubscription,
            expiresAt: subscription.expiresAt.map { Double($0.epochSeconds) },
            lastSyncedAt: subscription.lastSyncedAt.map { Double($0.epochSeconds) }
        )
    )
}

struct ProgressNumbers: ProgressWithOperations {
    let totalOperations: Int32
    let downloadedOperations: Int32
    
    init(source: PowerSyncKotlin.ProgressWithOperations) {
        self.totalOperations = source.totalOperations
        self.downloadedOperations = source.downloadedOperations
    }
}
