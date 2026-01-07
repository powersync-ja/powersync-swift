import GRDB
import GRDBQuery
import PowerSync
import SwiftUI

/// View which allows creating a new List
struct AddListSheet: View {
    @Environment(ViewModels.self) var viewModels

    @Binding var isPresented: Bool
    @State var newListName: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("New List")
                .font(.headline)
            TextField("List name", text: $newListName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($isTextFieldFocused)
                .padding()
            HStack {
                Button("Cancel") {
                    isPresented = false
                    newListName = ""
                }
                Spacer()
                Button("Add") {
                    do {
                        try viewModels.listViewModel.createList(name: newListName)
                        isPresented = false
                        newListName = ""
                    } catch {
                        // Don't close the dialog
                        print("Error adding list: \(error)")
                    }
                }
                .disabled(newListName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .onAppear {
            isTextFieldFocused = true
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    modalBackgroundColor
                )
                .shadow(radius: 8)
        )
    }
}
