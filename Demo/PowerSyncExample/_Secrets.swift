import Foundation

/// A protocol which specified the base structure for secrets
protocol SecretsProvider {
    static var powerSyncEndpoint: String { get }
    static var supabaseURL: URL { get }
    static var supabaseAnonKey: String { get }
    static var supabaseStorageBucket: String? { get }
}

/// A default implementation of [SecretsProvider].
/// This implementation ensures the app will compile even if no actual secrets are provided.
/// Devs should specify the actual secrets in a Git ignored file.
extension SecretsProvider {
    static var powerSyncEndpoint: String {
        return "TODO"
    }

    static var supabaseURL: URL {
        return  URL(string: "TODO")!
    }

    static var supabaseAnonKey: String {
        return "TODO"
    }

    static var supabaseStorageBucket: String? {
        return nil
    }
}


// Default conforming type
enum Secrets: SecretsProvider {}
