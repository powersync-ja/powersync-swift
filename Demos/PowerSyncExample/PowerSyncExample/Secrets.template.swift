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

    // Optional storage bucket name. Set to nil if you don't want to use storage.
    static var supabaseStorageBucket: String? {
        return nil
    }

    static var previewSyncStreams: Bool {
        /* 
        Set to true to preview https://docs.powersync.com/sync/streams/overview.
        When enabling this, also set your sync rules to the following:

        config:
          edition: 2

        streams:
          lists:
            query: SELECT * FROM lists WHERE owner_id = auth.user_id()
            auto_subscribe: true
          todos:
            query: SELECT * FROM todos WHERE list_id = subscription.parameter('list') AND list_id IN (SELECT id FROM lists WHERE owner_id = auth.user_id())
        */
        false
    }
}
