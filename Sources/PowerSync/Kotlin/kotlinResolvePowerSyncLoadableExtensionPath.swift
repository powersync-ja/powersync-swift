import PowerSyncKotlin

func kotlinResolvePowerSyncLoadableExtensionPath() throws -> String? {
    do {
        return try PowerSyncKotlin.resolvePowerSyncLoadableExtensionPath() 
    } catch {
        throw PowerSyncError.operationFailed(message: "Failed to resolve PowerSync loadable extension path: \(error.localizedDescription)")
    }
}