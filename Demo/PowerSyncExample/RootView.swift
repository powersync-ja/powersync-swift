import Auth
import SwiftUI

struct RootView: View {
    @Environment(PowerSyncManager.self) var powerSync

    @State private var authModel = AuthModel()
    @State private var navigationModel = NavigationModel()

    var body: some View {
        NavigationStack(path: $navigationModel.path) {
            Group {
                if authModel.isAuthenticated {
                    HomeScreen()
                } else {
                    SignInScreen()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                    case .home:
                        HomeScreen()
                    case .signIn:
                        SignInScreen()
                    case .signUp:
                        SignUpScreen()
                    }
            }
        }
        .task {
            if(powerSync.db == nil) {
                powerSync.openDb()
            }
        }
        .environment(authModel)
        .environment(navigationModel)
    }

}

#Preview {
    RootView()
        .environment(PowerSyncManager())
}
