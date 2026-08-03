import SwiftUI

enum Route: Hashable {
    case home
    case signIn
    case signUp
    case search
    case admin
}

@Observable
class NavigationModel {
    var path = NavigationPath()
}
