import PowerSyncKotlin

typealias KotlinPowerSyncBackendConnector = PowerSyncKotlin.PowerSyncBackendConnector
typealias KotlinPowerSyncCredentials = PowerSyncKotlin.PowerSyncCredentials
typealias KotlinPowerSyncDatabase = PowerSyncKotlin.PowerSyncDatabase

extension KotlinPowerSyncBackendConnector: @retroactive @unchecked Sendable {}
extension KotlinPowerSyncCredentials: @retroactive @unchecked Sendable {}
