import SwiftUI

enum Route: Hashable {
    case home
    case signIn
    case signUp
}

@Observable
class NavigationModel {
    var path = NavigationPath()
}
