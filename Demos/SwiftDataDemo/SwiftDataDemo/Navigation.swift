import SwiftUI

enum Route: Hashable {
    case signIn
    case signUp
    case todos(listId: String, listName: String)
}

@Observable
class NavigationModel {
    var path = NavigationPath()
}
