import Foundation
import PowerSync

let LISTS_TABLE = "lists"
let TODOS_TABLE = "todos"

let lists = Table(
    name: LISTS_TABLE,
    columns: [
        // ID column is automatically included
        Column(name: "name", type: ColumnType.text),
        Column(name: "created_at", type: ColumnType.text),
        Column(name: "owner_id", type: ColumnType.text)
    ],
    indexes: [],
    localOnly: false,
    insertOnly: false,
    viewNameOverride: LISTS_TABLE
)

let todos = Table(
    name: TODOS_TABLE,
    // ID column is automatically included
    columns: [
        Column(name: "list_id", type: ColumnType.text),
        Column(name: "photo_id", type: ColumnType.text),
        Column(name: "description", type: ColumnType.text),
        // 0 or 1 to represent false or true
        Column(name: "completed", type: ColumnType.integer),
        Column(name: "created_at", type: ColumnType.text),
        Column(name: "completed_at", type: ColumnType.text),
        Column(name: "created_by", type: ColumnType.text),
        Column(name: "completed_by", type: ColumnType.text)
        
    ],
    indexes: [
        Index(
            name: "list_id",
            columns: [IndexedColumn(column: "list_id", ascending: true, columnDefinition: nil, type: nil)]
        )
    ],
    localOnly: false,
    insertOnly: false,
    viewNameOverride: TODOS_TABLE
)

let AppSchema = Schema(tables: [lists, todos])
