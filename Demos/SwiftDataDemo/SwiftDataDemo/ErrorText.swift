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
