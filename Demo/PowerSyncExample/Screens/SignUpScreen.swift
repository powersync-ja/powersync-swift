import SwiftUI

private enum ActionState<Success, Failure: Error> {
    case idle
    case inFlight
    case result(Result<Success, Failure>)
}

struct SignUpScreen: View {
    @Environment(PowerSyncManager.self) private var powerSync
    @Environment(AuthModel.self) private var authModel
    @Environment(NavigationModel.self) private var navigationModel

    @State private var email = ""
    @State private var password = ""
    @State private var actionState = ActionState<Void, Error>.idle
    @State private var navigateToHome = false

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                Button("Sign up") {
                    Task {
                        await signUpButtonTapped()
                    }
                }
            }

            switch actionState {
                case .idle:
                    EmptyView()
                case .inFlight:
                    ProgressView()
                case let .result(.failure(error)):
                    ErrorText(error)
                case .result(.success):
                    Text("Sign up successful!")
            }
        }
    }


    private func signUpButtonTapped() async {
        do {
            actionState = .inFlight
            try await powerSync.connector.client.auth.signUp(
                email: email,
                password: password,
                redirectTo: Constants.redirectToURL
            )
            actionState = .result(.success(()))
            authModel.isAuthenticated = true
            navigationModel.path = NavigationPath()
        } catch {
            withAnimation {
                actionState = .result(.failure(error))
            }
        }
    }
}

#Preview {
    NavigationStack {
        SignUpScreen()
            .environment(PowerSyncManager())
    }
}
