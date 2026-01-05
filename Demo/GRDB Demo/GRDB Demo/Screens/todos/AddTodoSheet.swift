import GRDB
import GRDBQuery
import SwiftUI

/// View which allows creating a new Todo
struct AddTodoSheet: View {
    @Binding var isPresented: Bool
    @State var newTodoName: String = ""

    @FocusState private var isTextFieldFocused: Bool

    var onAdd: (String) throws -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Todo")
                .font(.headline)
            TextField("Todo name", text: $newTodoName)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .focused($isTextFieldFocused)
                .padding()
            HStack {
                Button("Cancel") {
                    isPresented = false
                    newTodoName = ""
                }
                Spacer()
                Button("Add") {
                    do {
                        try onAdd(newTodoName)
                        // Close the sheet
                        isPresented = false
                        newTodoName = ""
                    } catch {
                        // Don't close the sheet
                        print("Error adding todo: \(error)")
                    }
                }
                .disabled(newTodoName.trimmingCharacters(in: .whitespaces).isEmpty)
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
                .fill(modalBackgroundColor)
                .shadow(radius: 8)
        )
    }
}
