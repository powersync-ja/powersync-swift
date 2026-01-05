import Combine
import Supabase
import SwiftUI

class SupabaseViewModel: ObservableObject {
    let client: SupabaseClient
    @Published var session: Session?

    private var authTask: Task<Void, Never>?

    init(
        url: URL = Secrets.supabaseURL,
        anonKey: String = Secrets.supabaseAnonKey
    ) {
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey
        )

        // Start observing auth state changes
        authTask = Task { [weak self] in
            guard let self = self else {
                fatalError("Could not watch Supabase")
            }
            for await change in self.client.auth.authStateChanges {
                await MainActor.run {
                    self.session = change.session
                }
            }
        }
        // Set initial session
        session = client.auth.currentSession
    }

    deinit {
        authTask?.cancel()
    }

    func signIn(
        email: String,
        password: String,
        completion: @escaping (Result<Session, Error>) -> Void
    ) {
        Task {
            do {
                let session = try await client.auth.signIn(email: email, password: password)
                await MainActor.run {
                    self.session = session
                    completion(.success(session))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    
    func signOut(
        hook: @escaping () async throws -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                try await client.auth.signOut()
                try await hook()
                await MainActor.run {
                    self.session = nil
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    
    
    func register(
        email: String,
        password: String,
        completion: @escaping (Result<Session, Error>) -> Void
    ) {
        Task {
            do {
                let response = try await client.auth.signUp(email: email, password: password)
                await MainActor.run {
                    guard let session = response.session else {
                        completion(.failure(
                            NSError(
                                domain: "SupabaseModel",
                                code: 0,
                                userInfo: [NSLocalizedDescriptionKey: "No session returned. Please check your email for confirmation."]
                            )
                        ))
                        return
                    }
                    self.session = session
                    completion(.success(session))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
}
