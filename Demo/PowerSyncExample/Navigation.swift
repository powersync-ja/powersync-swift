import SwiftUI

enum Route: Hashable {
    case home
    case signIn
    case signUp
    case search
}

@Observable
class AuthModel {
    var isAuthenticated = false
}

@Observable
class NavigationModel {
    var path = NavigationPath()
}
