import SwiftUI

struct TodoListRow: View {
    let todo: Todo
    let isCameraAvailable: Bool
    let completeTapped: () -> Void
    let deletePhotoTapped: () -> Void
    let capturePhotoTapped: () -> Void
    let selectPhotoTapped: () -> Void

#if os(iOS)
    @State private var image: UIImage? = nil
#endif

    var body: some View {
        HStack {
            Text(todo.description)
#if os(iOS)
            Group {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                } else if todo.photoUri != nil {
                    // Show progress while loading the image
                    ProgressView()
                        .onAppear {
                            Task {
                                await loadImage()
                            }
                        }
                } else if todo.photoId != nil {
                    // Show progres, wait for a URI to be present
                    ProgressView()
                } else {
                    EmptyView()
                }
            }
#endif
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
#if os(iOS)
                if newPhotoId == nil {
                    // Clear the image when photoId becomes nil
                    image = nil
                }
#endif
            }
        }
    }

#if os(iOS)
    private func loadImage() async {
        guard let urlString = todo.photoUri else { return }
        let url = URL(fileURLWithPath: urlString)

        do {
            let data = try Data(contentsOf: url)
            if let loadedImage = UIImage(data: data) {
                image = loadedImage
            } else {
                print("Failed to decode image from data.")
            }
        } catch {
            print("Error loading image from disk:", error)
        }
    }
#endif
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
