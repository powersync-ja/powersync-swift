import PowerSyncKotlin
import Foundation

protocol KotlinSyncStatusDataProtocol: SyncStatusData {
    var base: PowerSyncKotlin.SyncStatusData { get }
}

struct KotlinSyncStatusData: KotlinSyncStatusDataProtocol {
    let base: PowerSyncKotlin.SyncStatusData
}

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
            timeIntervalSince1970: Double(lastSyncedAt.epochSeconds
                                         )
        )
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
    
    private func mapPriorityStatus(_ status: PowerSyncKotlin.PriorityStatusEntry) -> PriorityStatusEntry {
        var lastSyncedAt: Date?
        if let syncedAt = status.lastSyncedAt {
            lastSyncedAt = Date(timeIntervalSince1970: Double(syncedAt.epochSeconds))
        }
        
       return PriorityStatusEntry(
            priority: BucketPriority(status.priority),
            lastSyncedAt: lastSyncedAt,
            hasSynced: status.hasSynced?.boolValue
        )
    }
}
