import SwiftUI

struct TodoListRow: View {
    let todo: Todo
    let completeTapped: () -> Void
    let deletePhotoTapped: () -> Void
    let capturePhotoTapped: () -> Void

    @State private var image: UIImage? = nil

    var body: some View {
        HStack {
            Text(todo.description)
            Group {
                if todo.photoUri == nil {
                    // Nothing to display when photoURI is nil
                    EmptyView()
                } else if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if todo.photoUri != nil {
                    // Only show loading indicator if we have a URL string
                    ProgressView()
                        .onAppear {
                            loadImage()
                        }
                } else {
                    EmptyView()
                }
            }
            Spacer()
            VStack {
                if todo.photoId == nil {
                    Button {
                        capturePhotoTapped()
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        deletePhotoTapped()
                    } label: {
                        Image(systemName: "trash.fill")
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    completeTapped()
                } label: {
                    Image(systemName: todo.isComplete ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loadImage() {
        guard let urlString = todo.photoUri else {
            return
        }

        if let imageData = try? Data(contentsOf: URL(fileURLWithPath: urlString)),
           let loadedImage = UIImage(data: imageData)
        {
            image = loadedImage
        }
    }
}

#Preview {
    TodoListRow(
        todo: .init(
            id: UUID().uuidString.lowercased(),
            listId: UUID().uuidString.lowercased(),
            photoId: nil,
            description: "description",
            isComplete: false,
            createdAt: "",
            completedAt: nil,
            createdBy: UUID().uuidString.lowercased(),
            completedBy: nil,

        ),
        completeTapped: {},
        deletePhotoTapped: {}
    ) {}
}
