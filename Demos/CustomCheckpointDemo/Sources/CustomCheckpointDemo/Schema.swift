import PowerSync

let LISTS_TABLE = "lists"
let TODOS_TABLE = "todos"

let lists = Table(
    name: LISTS_TABLE,
    columns: [
        // ID column is automatically included
        .text("name"),
        .text("created_at"),
        .text("owner_id"),
    ]
)

let todos = Table(
    name: TODOS_TABLE,
    columns: [
        // ID column is automatically included
        .text("list_id"),
        .text("description"),
        // 0 or 1 to represent false or true
        .integer("completed"),
        .text("created_at"),
        .text("completed_at"),
        .text("created_by"),
        .text("completed_by"),
    ],
    indexes: [
        Index(
            name: "list_id",
            columns: [IndexedColumn.ascending("list_id")]
        ),
    ]
)

let AppSchema = Schema(lists, todos)
