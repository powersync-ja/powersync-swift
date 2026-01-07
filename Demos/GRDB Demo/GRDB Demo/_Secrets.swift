import Foundation

/// A protocol which specified the base structure for secrets
protocol SecretsProvider {
    static var powerSyncEndpoint: String { get }
    static var supabaseURL: URL { get }
    static var supabaseAnonKey: String { get }
}

// Default conforming type
enum Secrets: SecretsProvider {}
