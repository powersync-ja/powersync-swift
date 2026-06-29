import Foundation

/// A protocol which specifies the base structure for secrets
protocol SecretsProvider {
    static var powerSyncEndpoint: String { get }
    static var supabaseURL: URL { get }
    static var supabaseAnonKey: String { get }
}

// Default conforming type. The actual values live in `Secrets.swift`, which is gitignored;
// copy `Secrets.template.swift` to `Secrets.swift` and fill in your project's credentials.
enum Secrets: SecretsProvider {}
