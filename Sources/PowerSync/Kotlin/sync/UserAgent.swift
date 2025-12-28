import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

func userAgent() -> String {
    let libraryVersion = "1.0.0" // TODO: Replace with actual library version
    
    #if os(iOS)
    let osName = "iOS"
    let osVersion = UIDevice.current.systemVersion
    #elseif os(macOS)
    let osName = "macOS"
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(version.majorVersion).\(version.minorVersion)"
    #else
    let osName = "unknown"
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    #endif
    
    return "powersync-swift/\(libraryVersion) \(osName)/\(osVersion)"
}