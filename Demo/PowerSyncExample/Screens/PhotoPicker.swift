//import PhotosUI
//import SwiftUI
//
//struct PhotoPicker: View {
//    @State private var selectedImage: UIImage?
//    @State private var imageData: Data?
//    @State private var showImagePicker = false
//    @State private var showCamera = false
//
//    var body: some View {
//        VStack {
//            if let selectedImage = selectedImage {
//                Image(uiImage: selectedImage)
//                    .resizable()
//                    .scaledToFit()
//                    .frame(height: 300)
//
//                Text("Image data size: \(imageData?.count ?? 0) bytes")
//            }
//
//            HStack {
//                Button("Camera") {
//                    showCamera = true
//                }
//
//                Button("Photo Library") {
//                    showImagePicker = true
//                }
//            }
//        }
//        .sheet(isPresented: $showCamera) {
//            CameraView(image: $selectedImage, imageData: $imageData)
//        }
//    }
//}
//
//struct CameraView: UIViewControllerRepresentable {
//    @Binding var image: UIImage?
//    @Binding var imageData: Data?
//    @Environment(\.presentationMode) var presentationMode
//
//    func makeUIViewController(context: Context) -> UIImagePickerController {
//        let picker = UIImagePickerController()
//        picker.delegate = context.coordinator
//        picker.sourceType = .camera
//        return picker
//    }
//
//    func updateUIViewController(_: UIImagePickerController, context _: Context) {}
//
//    func makeCoordinator() -> Coordinator {
//        Coordinator(self)
//    }
//
//    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
//        let parent: CameraView
//
//        init(_ parent: CameraView) {
//            self.parent = parent
//        }
//
//        func imagePickerController(_: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
//            if let image = info[.originalImage] as? UIImage {
//                parent.image = image
//
//                // Convert UIImage to Data
//                if let jpegData = image.jpegData(compressionQuality: 0.8) {
//                    parent.imageData = jpegData
//                }
//            }
//
//            parent.presentationMode.wrappedValue.dismiss()
//        }
//
//        func imagePickerControllerDidCancel(_: UIImagePickerController) {
//            parent.presentationMode.wrappedValue.dismiss()
//        }
//    }
//}
