import Foundation

extension Secrets {
    static var powerSyncEndpoint: String {
        return "https://todo.powersync.com"
    }

    static var supabaseURL: URL {
        return  URL(string: "https://todo.supabase.co")!
    }

    static var supabaseAnonKey: String {
        return "TODO"
    }

    // Optional storage bucket name. Set to nil if you don't want to use storage.
    static var supabaseStorageBucket: String? {
        return nil
    }
}