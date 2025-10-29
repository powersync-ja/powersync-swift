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

    static var previewSyncStreams: Bool {
        /* 
        Set to true to preview https://docs.powersync.com/usage/sync-streams.
        When enabling this, also set your sync rules to the following:

        streams:
          lists:
            query: SELECT * FROM lists WHERE owner_id = auth.user_id()
            auto_subscribe: true
          todos:
            query: SELECT * FROM todos WHERE list_id = subscription.parameter('list') AND list_id IN (SELECT id FROM lists WHERE owner_id = auth.user_id())

        config:
          edition: 2

        */

        false
    }
}