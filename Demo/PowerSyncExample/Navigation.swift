import SwiftUI

enum Route: Hashable {
    case home
    case signIn
    case signUp
    case search
}

@Observable
class NavigationModel {
    var path = NavigationPath()
}
