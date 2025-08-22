import PowerSyncKotlin

typealias KotlinPowerSyncBackendConnector = PowerSyncKotlin.SwiftPowerSyncBackendConnector
typealias KotlinPowerSyncCredentials = PowerSyncKotlin.PowerSyncCredentials
typealias KotlinPowerSyncDatabase = PowerSyncKotlin.PowerSyncDatabase

extension KotlinPowerSyncBackendConnector: @retroactive @unchecked Sendable {}
extension KotlinPowerSyncCredentials: @retroactive @unchecked Sendable {}
extension PowerSyncKotlin.KermitLogger: @retroactive @unchecked Sendable {}
extension PowerSyncKotlin.SyncStatus: @retroactive @unchecked Sendable {}
