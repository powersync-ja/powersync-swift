/// Creates a PowerSync Schema table for attachment state
public func createAttachmentTable(name: String) -> Table {
    return Table(
        name: name,
        columns: [
            .integer("timestamp"),
            .integer("state"),
            .text("filename"),
            .integer("has_synced"),
            .text("local_uri"),
            .text("media_type"),
            .integer("size"),
            .text("meta_data"),
        ],
        localOnly: true
    )
}
