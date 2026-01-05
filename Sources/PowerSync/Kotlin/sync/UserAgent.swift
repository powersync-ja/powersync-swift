import Foundation

#if os(iOS) || os(tvOS)
import UIKit
#endif

func userAgent() -> String {
    #if os(macOS)
    let osName = "macOS"
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(version.majorVersion).\(version.minorVersion)"
    #elseif os(watchOS)
    let osName = "watchOS"
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(version.majorVersion).\(version.minorVersion)"
    #elseif os(iOS)
    let osName = "iOS"
    let osVersion = UIDevice.current.systemVersion
    #elseif os(tvOS)
    let osName = "tvOS"
    let osVersion = UIDevice.current.systemVersion
    #else
    let osName = "unknown"
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(version.majorVersion).\(version.minorVersion)"
    #endif
    
    return "powersync-swift/\(libraryVersion) \(osName)/\(osVersion)"
}
