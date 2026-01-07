import Foundation

extension Secrets {
    static var powerSyncEndpoint: String {
        return "http://localhost:8080"
    }

    static var supabaseURL: URL {
        return URL(string: "http://localhost:54321")!
    }

    static var supabaseAnonKey: String {
        // The default for local Supabase development
        return "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"
    }
}
