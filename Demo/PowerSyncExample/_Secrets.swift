import Foundation

// Enter your Supabase and PowerSync project details.
enum Secrets {
    static let powerSyncEndpoint = "https://your-id.powersync.journeyapps.com"
    static let supabaseURL = URL(string: "https://your-id.supabase.co")!
    static let supabaseAnonKey = "anon-key"
    // Optional storage bucket name. Set to nil if you don't want to use storage.
    static let supabaseStorageBucket: String? = nil
}