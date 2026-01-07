import GRDB
import GRDBQuery
import PowerSync
import SwiftUI

/// Main view for viewing and editing Lists
struct ListItemView: View {
    @Environment(ViewModels.self) var viewModels

    var list: ListWithTodoCounts
    let onOpen: () -> Void

    var body: some View {
        VStack {
            HStack {
                Text(list.name).font(.title)
                Spacer()
                Button {
                    onOpen()
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(BorderlessButtonStyle())
                #if os(macOS)
                    Button {
                        try? viewModels.listViewModel.deleteList(id: list.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .foregroundColor(.red)
                #endif
            }
            HStack {
                if list.pendingCount > 0 {
                    Text("\(list.pendingCount) Pending")
                        .font(.subheadline)
                }
                Spacer()
            }
        }
        .padding()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                try? viewModels.listViewModel.deleteList(id: list.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
