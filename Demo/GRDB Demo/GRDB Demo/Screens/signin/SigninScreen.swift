import SwiftUI

struct SigninScreen: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var errorMessage: String?
    @State private var busy = false

    @FocusState private var emailFieldFocused: Bool

    @Environment(ViewModels.self) var viewModels

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0 / 255, green: 33 / 255, blue: 98 / 255), // #002162
                    Color(red: 10 / 255, green: 43 / 255, blue: 120 / 255) // Slightly lighter blue
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .padding(.top, 40)

                Text(isRegistering ? "Register" : "Sign In")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.white)

                VStack(spacing: 16) {
                    TextField("Email", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    #if os (iOS) || os (tvOS) || targetEnvironment(macCatalyst)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                    #endif
                        .focused($emailFieldFocused)

                    SecureField("Password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.horizontal, 32)

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Button(isRegistering ? "Register" : "Sign In") {
                    if email.isEmpty || password.isEmpty {
                        errorMessage = "Please enter both email and password."
                        return
                    }
                    errorMessage = nil
                    busy = true
                    if isRegistering {
                        viewModels.supabaseViewModel.register(
                            email: email,
                            password: password
                        ) { result in
                            switch result {
                            case .success:
                                break
                            // Don't need to do anything, will be automatically navigated
                            case let .failure(error):
                                errorMessage = "Could not register: \(error)"
                            }
                            busy = false
                        }
                    } else {
                        viewModels.supabaseViewModel.signIn(
                            email: email,
                            password: password
                        ) { result in
                            switch result {
                            case .success:
                                // Don't need to do anything, will be automatically navigated
                                break
                            case let .failure(error):
                                errorMessage = "Could not login: \(error)"
                            }
                            busy = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .foregroundColor(.white)
                .padding(.horizontal, 32)

                Button(isRegistering ? "Already have an account? Sign In" : "Don't have an account? Register") {
                    isRegistering.toggle()
                    errorMessage = nil
                }
                .font(.footnote)
                .padding(.top, 8)
                .foregroundColor(.white)
            }
            .padding()
            .onAppear {
                emailFieldFocused = true
            }
        }
    }
}

#Preview {
    SigninScreen()
        .environment(
            ViewModels(databases: openDatabase()
            )
        )
}
