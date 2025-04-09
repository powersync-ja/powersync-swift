import IdentifiedCollections
import SwiftUI
import SwiftUINavigation

struct TodoListView: View {
    @Environment(SystemManager.self) private var system
    let listId: String

    @State private var todos: IdentifiedArrayOf<Todo> = []
    @State private var error: Error?
    @State private var newTodo: NewTodo?
    @State private var editing: Bool = false
    
    @State private var selectedImage: UIImage?
    @State private var imageData: Data?
    @State private var showCamera = false

    var body: some View {
        List {
            if let error {
                ErrorText(error)
            }

            IfLet($newTodo) { $newTodo in
                AddTodoListView(newTodo: $newTodo, listId: listId) { _ in
                    withAnimation {
                        self.newTodo = nil
                    }
                }
            }

            ForEach(todos) { todo in
                TodoListRow(
                    todo: todo,
                    completeTapped: {
                        Task {
                            await toggleCompletion(of: todo)
                        }
                    },
                    deletePhotoTapped: {
                        guard let attachments = system.attachments,
                              let attachmentID = todo.photoId
                        else {
                            return
                        }
                        Task {
                            do {
                                _ = try await attachments.deleteFile(attachmentId: attachmentID) { tx, _ in
                                    _ = try tx.execute(sql: "UPDATE \(TODOS_TABLE) SET photo_id = NULL WHERE id = ?", parameters: [todo.id])
                                }
                            } catch {
                                self.error = error
                            }
                        }

                    },
                    capturePhotoTapped: {
                        showCamera = true
                    }
                )
            }
            .onDelete { indexSet in
                Task {
                    await delete(at: indexSet)
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraView(imageData: $imageData)
        }
        .animation(.default, value: todos)
        .navigationTitle("Todos")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if newTodo == nil {
                    Button {
                        withAnimation {
                            newTodo = .init(
                                listId: listId,
                                isComplete: false,
                                description: ""
                            )
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                } else {
                    Button("Cancel", role: .cancel) {
                        withAnimation {
                            newTodo = nil
                        }
                    }
                }
            }
        }
        .task {
            await system.watchTodos(listId) { tds in
                withAnimation {
                    self.todos = IdentifiedArrayOf(uniqueElements: tds)
                }
            }
        }
    }

    func toggleCompletion(of todo: Todo) async {
        var updatedTodo = todo
        updatedTodo.isComplete.toggle()
        do {
            error = nil
            try await system.updateTodo(updatedTodo)
        } catch {
            self.error = error
        }
    }

    func delete(at offset: IndexSet) async {
        do {
            error = nil
            let todosToDelete = offset.map { todos[$0] }

            try await system.deleteTodo(id: todosToDelete[0].id)

        } catch {
            self.error = error
        }
    }
}

#Preview {
    NavigationStack {
        TodoListView(
            listId: UUID().uuidString.lowercased()
        ).environment(SystemManager())
    }
}


struct CameraView: UIViewControllerRepresentable {
    @Binding var imageData: Data?
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                // Convert UIImage to Data
                if let jpegData = image.jpegData(compressionQuality: 0.8) {
                    parent.imageData = jpegData
                }
            }

            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
