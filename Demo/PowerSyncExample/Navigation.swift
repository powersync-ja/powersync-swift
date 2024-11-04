import SwiftUI

enum Route: Hashable {
    case home
    case signIn
    case signUp
}

@Observable
class AuthModel {
    var isAuthenticated = false
}

@Observable
class NavigationModel {
    var path = NavigationPath()
}
