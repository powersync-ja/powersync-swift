import GRDB
import GRDBQuery
import PowerSync
import SwiftUI

struct ListsScreen: View {
    @Query(ListsWithTodoCountsRequest())
    var lists: [ListWithTodoCounts]

    @Environment(ViewModels.self) var viewModels

    @State private var showingAddSheet = false
    @State private var selectedList: ListWithTodoCounts?

    var body: some View {
        NavigationStack {
            StatusIndicatorView {
                ZStack {
                    SwiftUI.List(lists) { list in
                        ListItemView(
                            list: list
                        ) {
                            selectedList = list
                        }
                    }

                    // Floating Action Button
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                showingAddSheet = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding()
                                    .background(Circle().fill(Color.accentColor))
                                    .shadow(radius: 4)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .padding()
                            .accessibilityLabel("Create New List")
                        }
                    }
                    // Modal overlay
                    if showingAddSheet {
                        Color.black.opacity(0.3) // Dimmed background
                            .ignoresSafeArea()
                        AddListSheet(isPresented: $showingAddSheet)
                            .frame(width: 300)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(modalBackgroundColor)
                                    .shadow(radius: 8)
                            )
                            .transition(.scale)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewModels.supabaseViewModel.signOut {
                            try await viewModels.databases.powerSync.disconnectAndClear()
                        } completion: { _ in }
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Todo Lists")
            // Navigation to TodosView
            .navigationDestination(item: $selectedList) { list in
                TodosView(list: list)
            }
        }
        .task {
            // Automatically connect on startup
            try? await viewModels.errorViewModel.withReportingAsync {
                try await viewModels.databases.powerSync.connect(
                    connector: SupabaseConnector(
                        supabase: viewModels.supabaseViewModel
                    )
                )
            }
        }
    }
}

#Preview {
    ListsScreen()
        .environment(
            ViewModels(
                databases: openDatabase()
            )
        )
}
