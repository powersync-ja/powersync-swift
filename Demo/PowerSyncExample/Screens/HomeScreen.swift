import Foundation
import Auth
import SwiftUI

struct HomeScreen: View {
    @Environment(PowerSyncManager.self) private var powerSync
    @Environment(AuthModel.self) private var authModel
    @Environment(NavigationModel.self) private var navigationModel

    
      var body: some View {

        ListView()
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Sign out") {
                Task { 
                    try await powerSync.signOut()
                    authModel.isAuthenticated = false
                    navigationModel.path = NavigationPath()
                }
              }
            }
          }
          .task {
              if(powerSync.db.currentStatus.connected == false) {
                  await powerSync.connect()
              }
          }
          .navigationBarBackButtonHidden(true)
        }
}

#Preview {
    NavigationStack{
        HomeScreen()
            .environment(PowerSyncManager())
    }
}
