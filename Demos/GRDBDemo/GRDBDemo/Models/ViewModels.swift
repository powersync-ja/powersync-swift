import Combine
import GRDB
import GRDBQuery
import PowerSync
import SwiftUI

@Observable
class ViewModels {
    let errorViewModel: ErrorViewModel
    let listViewModel: ListViewModel
    let todoViewModel: TodoViewModel
    let supabaseViewModel: SupabaseViewModel

    let databases: Databases

    init(
        databases: Databases,
    ) {
        self.databases = databases
        errorViewModel = ErrorViewModel()
        supabaseViewModel = SupabaseViewModel()
        listViewModel = ListViewModel(
            grdb: databases.grdb,
            errorModel: errorViewModel,
            supabaseModel: supabaseViewModel
        )
        todoViewModel = TodoViewModel(
            grdb: databases.grdb,
            errorModel: errorViewModel
        )
    }
    
}
