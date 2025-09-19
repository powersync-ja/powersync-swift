import PowerSyncKotlin

typealias KotlinSwiftBackendConnector = PowerSyncKotlin.SwiftBackendConnector
typealias KotlinPowerSyncBackendConnector = PowerSyncKotlin.PowerSyncBackendConnector
typealias KotlinPowerSyncCredentials = PowerSyncKotlin.PowerSyncCredentials
typealias KotlinPowerSyncDatabase = PowerSyncKotlin.PowerSyncDatabase

extension KotlinPowerSyncBackendConnector: @retroactive @unchecked Sendable {}
extension KotlinPowerSyncCredentials: @retroactive @unchecked Sendable {}
extension PowerSyncKotlin.KermitLogger: @retroactive @unchecked Sendable {}
extension PowerSyncKotlin.SyncStatus: @retroactive @unchecked Sendable {}

extension PowerSyncKotlin.CrudEntry: @retroactive @unchecked Sendable {}
extension PowerSyncKotlin.CrudBatch: @retroactive @unchecked Sendable {}
extension PowerSyncKotlin.CrudTransaction: @retroactive @unchecked Sendable {}
