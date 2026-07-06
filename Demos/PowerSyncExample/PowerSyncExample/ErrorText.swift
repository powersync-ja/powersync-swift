import SwiftUI

struct ErrorText: View {
  let error: Error

  init(_ error: Error) {
    self.error = error
  }

  var body: some View {
    Text(error.localizedDescription)
      .foregroundColor(.red)
      .font(.footnote)
  }
}

struct ErrorText_Previews: PreviewProvider {
  static var previews: some View {
    ErrorText(NSError())
  }
}

extension Binding where Value == Error? {
    /// Clears any previously captured error, runs the given operation,
    /// and stores a thrown error in this binding.
    ///
    /// Allows views to call throwing `SystemManager` methods directly while
    /// reporting failures through their local error state:
    /// ```swift
    /// await $error.catching {
    ///     try await system.refreshFromRemote()
    /// }
    /// ```
    @MainActor
    func catching(_ operation: @MainActor () async throws -> Void) async {
        wrappedValue = nil
        do {
            try await operation()
        } catch {
            wrappedValue = error
        }
    }
}
