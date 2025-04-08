import SwiftUI

struct TodoListRow: View {
  let todo: Todo
  let completeTapped: () -> Void
    @State private var image: UIImage? = nil

  var body: some View {
    HStack {
      Text(todo.description)
        Group {
            if (todo.photoUri == nil) {
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
                    }}
            else {
                                EmptyView()
                            }
                  
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
    
    private func loadImage() {
        guard let urlString = todo.photoUri else {
            return
        }
        let url = URL(fileURLWithPath: urlString)
        
        if let imageData = try? Data(contentsOf: url),
           let loadedImage = UIImage(data: imageData) {
            self.image = loadedImage
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
        completedBy: nil
      )
    ) {}
}
