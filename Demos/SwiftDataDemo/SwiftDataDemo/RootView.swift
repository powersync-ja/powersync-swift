import Auth
import SwiftUI

struct RootView: View {
    @Environment(SystemManager.self) private var system

    @State private var navigationModel = NavigationModel()

    var body: some View {
        NavigationStack(path: $navigationModel.path) {
            Group {
                if system.connector.session != nil {
                    ListsScreen()
                } else {
                    SignInScreen()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .signIn:
                    SignInScreen()
                case .signUp:
                    SignUpScreen()
                case let .todos(listId, listName):
                    TodosScreen(listId: listId, listName: listName)
                }
            }
        }
        .environment(navigationModel)
    }
}
