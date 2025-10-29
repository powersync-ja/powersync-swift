import Foundation
import PowerSyncKotlin

/// A protocol extension which allows sharing common implementation using a base sync status
protocol KotlinSyncStatusDataProtocol: SyncStatusData {
    var base: PowerSyncKotlin.SyncStatusData { get }
}

struct KotlinSyncStatusData: KotlinSyncStatusDataProtocol,
    // We can't override the PowerSyncKotlin.SyncStatusData's Sendable status
    @unchecked Sendable
{
    let base: PowerSyncKotlin.SyncStatusData
}

/// Extension of `KotlinSyncStatusDataProtocol` which uses the shared `base` to implement `SyncStatusData`
extension KotlinSyncStatusDataProtocol {
    var connected: Bool {
        base.connected
    }

    var connecting: Bool {
        base.connecting
    }

    var downloading: Bool {
        base.downloading
    }

    var uploading: Bool {
        base.uploading
    }

    var lastSyncedAt: Date? {
        guard let lastSyncedAt = base.lastSyncedAt else { return nil }
        return Date(
            timeIntervalSince1970: Double(
                lastSyncedAt.epochSeconds
            )
        )
    }

    var downloadProgress: (any SyncDownloadProgress)? {
        guard let kotlinProgress = base.downloadProgress else { return nil }
        return KotlinSyncDownloadProgress(progress: kotlinProgress)
    }

    var hasSynced: Bool? {
        base.hasSynced?.boolValue
    }

    var uploadError: Any? {
        base.uploadError
    }

    var downloadError: Any? {
        base.downloadError
    }

    var anyError: Any? {
        base.anyError
    }

    public var priorityStatusEntries: [PriorityStatusEntry] {
        base.priorityStatusEntries.map { mapPriorityStatus($0) }
    }

    public func statusForPriority(_ priority: BucketPriority) -> PriorityStatusEntry {
        mapPriorityStatus(
            base.statusForPriority(
                priority: Int32(priority.priorityCode)
            )
        )
    }
    
    var syncStreams: [SyncStreamStatus]? {
        return base.syncStreams?.map(mapSyncStreamStatus)
    }

    func forStream(stream: SyncStreamDescription) -> SyncStreamStatus? {
        var rawStatus: Optional<PowerSyncKotlin.SyncStreamStatus>
        if let kotlinStream = stream as? any HasKotlinStreamDescription {
            // Fast path: Reuse Kotlin stream object for lookup.
            rawStatus = base.forStream(stream: kotlinStream.kotlinDescription)
        } else {
            // Custom stream description, we have to convert parameters to a Kotlin map.
            let parameters = stream.parameters?.mapValues { $0.toValue() }
            rawStatus = syncStatusForStream(status: base, name: stream.name, parameters: parameters)
        }
        
        return rawStatus.map(mapSyncStreamStatus)
    }

    private func mapPriorityStatus(_ status: PowerSyncKotlin.PriorityStatusEntry) -> PriorityStatusEntry {
        var lastSyncedAt: Date?
        if let syncedAt = status.lastSyncedAt {
            lastSyncedAt = Date(
                timeIntervalSince1970: Double(syncedAt.epochSeconds)
            )
        }

        return PriorityStatusEntry(
            priority: BucketPriority(status.priority),
            lastSyncedAt: lastSyncedAt,
            hasSynced: status.hasSynced?.boolValue
        )
    }
}

protocol KotlinProgressWithOperationsProtocol: ProgressWithOperations {
    var base: any PowerSyncKotlin.ProgressWithOperations { get }
}

extension KotlinProgressWithOperationsProtocol {
    var totalOperations: Int32 {
        return base.totalOperations
    }

    var downloadedOperations: Int32 {
        return base.downloadedOperations
    }
}

struct KotlinProgressWithOperations: KotlinProgressWithOperationsProtocol,
    // We can't mark  PowerSyncKotlin.ProgressWithOperations as Sendable
    @unchecked Sendable
{
    let base: PowerSyncKotlin.ProgressWithOperations
}

struct KotlinSyncDownloadProgress: KotlinProgressWithOperationsProtocol, SyncDownloadProgress,
    // We can't mark  PowerSyncKotlin.SyncDownloadProgress as Sendable
    @unchecked Sendable
{
    let progress: PowerSyncKotlin.SyncDownloadProgress

    var base: any PowerSyncKotlin.ProgressWithOperations {
        progress
    }

    func untilPriority(priority: BucketPriority) -> any ProgressWithOperations {
        return KotlinProgressWithOperations(base: progress.untilPriority(priority: priority.priorityCode))
    }
}
