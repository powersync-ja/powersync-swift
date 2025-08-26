import Auth
import SwiftUI

struct RootView: View {
    @Environment(SystemManager.self) var system
    
    @State private var navigationModel = NavigationModel()

    var body: some View {
        NavigationStack(path: $navigationModel.path) {
            Group {
                if system.connector.session != nil {
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
        .environment(navigationModel)
    }
}

#Preview {
    RootView()
        .environment(SystemManager())
}
