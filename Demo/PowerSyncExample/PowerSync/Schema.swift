import Foundation
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
    // ID column is automatically included
    columns: [
        Column.text("list_id"),
        Column.text("photo_id"),
        Column.text("description"),
        // 0 or 1 to represent false or true
        Column.integer("completed"),
        Column.text("created_at"),
        Column.text("completed_at"),
        Column.text("created_by"),
        Column.text("completed_by"),
    ],
    indexes: [
        Index(
            name: "list_id",
            columns: [IndexedColumn.ascending("list_id")]
        ),
    ]
)

let AppSchema = Schema(
    lists,
    todos,
    createAttachmentTable(name: "attachments")
)
