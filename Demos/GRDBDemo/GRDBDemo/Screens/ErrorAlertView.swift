import SwiftUI

/// A Simple View which presents the latest error state from the `ErrorViewModel`
struct ErrorAlertView<Content: View>: View {
    @Environment(ViewModels.self) var viewModels
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .alert(isPresented: Binding<Bool>(
                get: { viewModels.errorViewModel.errorMessage != nil },
                set: { newValue in
                    if !newValue { viewModels.errorViewModel.clear() }
                }
            )) {
                Alert(
                    title: Text("Error"),
                    message: Text(viewModels.errorViewModel.errorMessage ?? ""),
                    dismissButton: .default(Text("OK")) {
                        viewModels.errorViewModel.clear()
                    }
                )
            }
    }
}
