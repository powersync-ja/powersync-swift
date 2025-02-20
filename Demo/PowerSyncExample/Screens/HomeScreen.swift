import Foundation
import Auth
import SwiftUI

struct HomeScreen: View {
    @Environment(SystemManager.self) private var system
    @Environment(AuthModel.self) private var authModel
    @Environment(NavigationModel.self) private var navigationModel
    @State private var isSigningOut = false

    var body: some View {
        ListView()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        signOut()
                    } label: {
                        if isSigningOut {
                            HStack {
                                Text("Signing out")
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.7)
                            }
                        } else {
                            Text("Sign out")
                        }
                    }
                    .disabled(isSigningOut)
                }
            }
            .task {
                if(system.db.currentStatus.connected == false) {
                    await system.connect()
                }
            }
            .navigationBarBackButtonHidden(true)
    }

    private func signOut() {
        Task {
            isSigningOut = true
            do {
                try await system.signOut()
                authModel.isAuthenticated = false
                navigationModel.path = NavigationPath()
            } catch {
                print("Sign out error: \(error)")
            }
            isSigningOut = false
        }
    }
}

#Preview {
    NavigationStack{
        HomeScreen()
            .environment(SystemManager())
    }
}
