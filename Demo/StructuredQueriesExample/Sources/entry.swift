import Foundation
import PowerSync
import PowerSyncStructuredQueries
import StructuredQueries

@StructuredQueries.Table("users")
struct User {
    var id: String
    var name: String
    var birthday: Date?
}

@StructuredQueries.Table("posts")
struct Post {
    var id: String
    var description: String
    // TODO, inserts seem to break with this
    @StructuredQueries.Column("user_id")
    var userId: String
}

@main
struct Main {
    static func main() async throws {
        // TODO, check if the schema can be shared in some way
        let powersync = PowerSyncDatabase(
            schema: Schema(
                tables: [
                    Table(
                        name: "users",
                        columns: [
                            .text("name"),
                            .text("birthday"),
                        ]
                    ),
                    Table(
                        name: "posts",
                        columns: [
                            .text("description"),
                            .text("user_id"),
                        ]
                    ),
                ],
            ),
            dbFilename: "test.sqlite"
        )

        let testUserID = UUID().uuidString

        try await User.insert {
            ($0.id, $0.name, $0.birthday)
        } values: {
            (testUserID, "Steven", Date())
        }.execute(powersync)

        try await User.insert {
            User(
                id: UUID().uuidString,
                name: "Nevets"
            )
        }.execute(powersync)

        let users = try await User.all.fetchAll(powersync)
        print("The users are:")
        for user in users {
            print(user)
        }

        // TODO: column aliases seem to be broken
        // try await Post.insert { Post(
        //     id: UUID().uuidString, description: "A Post", userId: testUserID
        // ) }.execute(powersync)

        // // TODO: fix typing in order to execute joined queries
        // let postsWithUsers = Post.join(User.all) { $0.userId == $1.id }
        //     .select { ($0.description, $1.name) }
    }
}
