import SwiftUI

struct TodoListRow: View {
    let todo: Todo
    let isCameraAvailable: Bool
    let completeTapped: () -> Void
    let deletePhotoTapped: () -> Void
    let capturePhotoTapped: () -> Void
    let selectPhotoTapped: () -> Void

    @State private var image: UIImage? = nil

    var body: some View {
        HStack {
            Text(todo.description)
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                } else if todo.photoUri != nil {
                    // Show progress while loading the image
                    ProgressView()
                        .onAppear {
                            loadImage()
                        }
                } else if todo.photoId != nil {
                    // Show progres, wait for a URI to be present
                    ProgressView()
                } else {
                    EmptyView()
                }
            }
            Spacer()
            VStack {
                if todo.photoId == nil {
                    HStack {
                        if isCameraAvailable {
                            Button {
                                capturePhotoTapped()
                            } label: {
                                Image(systemName: "camera.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            selectPhotoTapped()
                        } label: {
                            Image(systemName: "photo.on.rectangle")
                        }
                        .buttonStyle(.plain)
                    }
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
            }.onChange(of: todo.photoId) { _, newPhotoId in
                if newPhotoId == nil {
                    // Clear the image when photoId becomes nil
                    image = nil
                }
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
        isCameraAvailable: true,
        completeTapped: {},
        deletePhotoTapped: {},
        capturePhotoTapped: {}
    ) {}
}
