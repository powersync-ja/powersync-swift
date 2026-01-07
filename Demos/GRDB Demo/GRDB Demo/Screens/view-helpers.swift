import SwiftUI

var modalBackgroundColor: Color {
    #if os(iOS)
    return Color(.systemGray6)
    #else
    return Color(nsColor: .windowBackgroundColor)
    #endif
}
