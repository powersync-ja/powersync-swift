import Foundation
import SwiftUI


struct WifiIcon: View {
    let isConnected: Bool
    
    var body: some View {
        let iconName = isConnected ? "wifi" : "wifi.slash"
        let description = isConnected ? "Online" : "Offline"
        
        Image(systemName: iconName)
            .accessibility(label: Text(description))
    }
}

#Preview {
    VStack {
        WifiIcon(isConnected: true)
        WifiIcon(isConnected: false)
    }
}
