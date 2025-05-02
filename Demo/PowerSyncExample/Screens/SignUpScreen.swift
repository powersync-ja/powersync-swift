import SwiftUI

private enum ActionState<Success, Failure: Error> {
    case idle
    case inFlight
    case result(Result<Success, Failure>)
}

struct SignUpScreen: View {
    @Environment(SystemManager.self) private var system
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
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
#if os(ios)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
#endif

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
#if os(ios)
                    .textInputAutocapitalization(.never)
#endif
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
            try await system.connector.client.auth.signUp(
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
            .environment(SystemManager())
    }
}
