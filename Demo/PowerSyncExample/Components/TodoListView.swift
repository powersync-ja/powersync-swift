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

    // Called when a photo has been captured. Individual widgets should register the listener
    @State private var onMediaSelect: ((_: Data) async throws -> Void)?
    @State private var pickMediaType: UIImagePickerController.SourceType = .camera
    @State private var showMediaPicker = false

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
                                try await attachments.deleteFile(attachmentId: attachmentID) { tx, _ in
                                    _ = try tx.execute(sql: "UPDATE \(TODOS_TABLE) SET photo_id = NULL WHERE id = ?", parameters: [todo.id])
                                }
                            } catch {
                                self.error = error
                            }
                        }

                    },
                    capturePhotoTapped: {
                        registerMediaCallback(todo: todo)
                        pickMediaType = .camera
                        showMediaPicker = true
                    },
                    selectPhotoTapped: {
                        registerMediaCallback(todo: todo)
                        pickMediaType = .photoLibrary
                        showMediaPicker = true
                    }
                )
            }
            .onDelete { indexSet in
                Task {
                    let selectedItems = indexSet.compactMap { index in
                        todos.indices.contains(index) ? todos[index] : nil
                    }
                    for try todo in selectedItems {
                        await delete(todo: todo)
                    }
                }
            }
        }
        .sheet(isPresented: $showMediaPicker) {
            CameraView(
                onMediaSelect: $onMediaSelect,
                mediaType: $pickMediaType
            )
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

    func delete(todo: Todo) async {
        do {
            error = nil
            try await system.deleteTodo(todo: todo)

        } catch {
            self.error = error
        }
    }
    
    ///  Registers a callback which saves a photo for the specified Todo item if media is sucessfully loaded.
    func registerMediaCallback(todo: Todo) {
        // Register a callback for successful image capture
        onMediaSelect = { (_ fileData: Data) in
            guard let attachments = system.attachments
            else {
                return
            }

            do {
                try await attachments.saveFile(
                    data: fileData,
                    mediaType: "image/jpeg",
                    fileExtension: "jpg"
                ) { tx, record in
                    _ = try tx.execute(
                        sql: "UPDATE \(TODOS_TABLE) SET photo_id = ? WHERE id = ?",
                        parameters: [record.id, todo.id]
                    )
                }
            } catch {
                self.error = error
            }
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
    @Binding var onMediaSelect: ((_: Data) async throws -> Void)?
    @Binding var mediaType: UIImagePickerController.SourceType
    
    @Environment(\.presentationMode) var presentationMode

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = mediaType
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
                    if let photoCapture = parent.onMediaSelect {
                        Task {
                            do {
                                try await photoCapture(jpegData)
                            } catch {
                                // The photoCapture method should handle errors
                                print("Error saving photo: \(error)")
                            }
                        }
                    }
                }
            }

            parent.presentationMode.wrappedValue.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}
