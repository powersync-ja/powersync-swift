
import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

func userAgent() async -> String {
#if os(macOS)
    let osName = "macOS"
#elseif os(watchOS)
    let osName = "watchOS"
#elseif os(iOS)
    let osName = "iOS"
#elseif os(tvOS)
    let osName = "tvOS"
#else
    let osName = "unknown"
#endif
    let osVersion = await getOSVersion()
    return "powersync-swift/\(libraryVersion) \(osName)/\(osVersion)"
}

// Returns the OS version string for the current platform
@MainActor func getOSVersion() async -> String {
#if os(iOS) || os(tvOS)
    // UIDevice must be accessed on the main actor
    return UIDevice.current.systemVersion
#else
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion)"
#endif
}
