import Auth
import SwiftUI

struct RootView: View {
    @Environment(SystemManager.self) var system

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
                    case .search:
                        SearchScreen()
                    }
            }
        }
        .task {
            if(system.db == nil) {
                do {
                    try await system.openDb()
                    await system.connect()
                } catch {
                    print("Failed to open db: \(error.localizedDescription)")
                }
            }
        }
        .environment(authModel)
        .environment(navigationModel)
    }

}

#Preview {
    RootView()
        .environment(SystemManager())
}
