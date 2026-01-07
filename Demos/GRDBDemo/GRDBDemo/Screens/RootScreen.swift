import Auth
import SwiftUI

struct RootScreen: View {
    @ObservedObject var supabaseViewModel: SupabaseViewModel

    var body: some View {
        if supabaseViewModel.session != nil {
            ListsScreen()
        } else {
            SigninScreen()
        }
    }
}
