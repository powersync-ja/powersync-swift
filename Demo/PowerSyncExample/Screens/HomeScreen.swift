import Foundation
import Auth
import SwiftUI

struct HomeScreen: View {
    @Environment(SystemManager.self) private var system
    @Environment(NavigationModel.self) private var navigationModel

    
      var body: some View {

        ListView()
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Sign out") {
                Task { 
                    try await system.signOut()
                    navigationModel.path = NavigationPath()
                }
              }
            }
          }
          .task {
              if(system.db.currentStatus.connected == false) {
                  await system.connect()
              }
          }
          .navigationBarBackButtonHidden(true)
        }
}

#Preview {
    NavigationStack{
        HomeScreen()
            .environment(SystemManager())
            .environment(NavigationModel())
    }
}
