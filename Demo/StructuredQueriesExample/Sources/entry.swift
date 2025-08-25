import Foundation
import PowerSync
import PowerSyncStructuredQueries
import StructuredQueries

@Table("users")
struct User {
    var id: String
    var name: String
    var birthday: Date?
}

@Table("posts")
struct Post {
    var id: String
    var description: String
    @Column("user_id")
    var userId: String
}

@Selection
struct JoinedResult {
    let postDescription: String
    let userName: String
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
                            .text("birthday")
                        ]
                    ),
                    Table(
                        name: "posts",
                        columns: [
                            .text("description"),
                            .text("user_id")
                        ]
                    ),
                ],
            ),
            dbFilename: "tests.sqlite"
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

        let posts = try await Post.all.fetchAll(powersync)
        print("The posts are:")
        for post in posts {
            print(post)
        }

        try await Post.insert {
            Post(
                id: UUID().uuidString, description: "A Post", userId: testUserID
            )
        }.execute(powersync)

        print("Joined posts are:")
        let joinedPosts = try await Post.join(User.all) { $0.userId == $1.id }
            .select {
                JoinedResult.Columns(
                    postDescription: $0.description,
                    userName: $1.name
                )
            }
            .fetchAll(powersync)
        for joinedResult in joinedPosts {
            print(joinedResult)
        }
    }
}
