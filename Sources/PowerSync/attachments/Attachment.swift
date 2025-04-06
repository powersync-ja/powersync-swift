/**
 * Enum for the attachment state
 */
public enum AttachmentState: Int {
    case queuedDownload
    case queuedUpload
    case queuedDelete
    case synced
    case archived
}

/**
 * Struct representing an attachment
 */
public struct Attachment {
    let id: String
    let timestamp: Int
    let filename: String
    let state: Int
    let localUri: String?
    let mediaType: String?
    let size: Int64?
    /**
     * Specifies if the attachment has been synced locally before. This is particularly useful
     * for restoring archived attachments in edge cases.
     */
    let hasSynced: Int?
    
    public init(
        id: String,
        filename: String,
        state: Int,
        timestamp: Int = 0,
        hasSynced: Int? = 0,
        localUri: String? = nil,
        mediaType: String? = nil,
        size: Int64? = nil,
    ) {
        self.id = id
        self.timestamp = timestamp
        self.filename = filename
        self.state = state
        self.localUri = localUri
        self.mediaType = mediaType
        self.size = size
        self.hasSynced = hasSynced
    }
    
    func with(filename: String? = nil, state: Int? = nil, hasSynced: Int? = nil, localUri: String? = nil, mediaType: String? = nil, size: Int64? = nil ) -> Attachment {
            return Attachment(
                id: self.id,
                filename: self.filename,
                state: state ?? self.state,
                hasSynced: hasSynced ?? self.hasSynced,
                localUri: localUri ?? self.localUri,
                mediaType: mediaType ?? self.mediaType,
                size: size ?? self.size,
            )
        }
    
    public static func fromCursor(_ cursor: SqlCursor) throws ->  Attachment {
        return  Attachment(
            id: try cursor.getString(name: "id"),
            filename: try cursor.getString(name: "filename"),
            state: try cursor.getLong(name: "state"),
            timestamp: try cursor.getLong(name: "timestamp"),
            hasSynced: try cursor.getLongOptional(name: "has_synced"),
            localUri: try cursor.getStringOptional(name: "local_uri"),
            mediaType: try cursor.getStringOptional(name: "media_type"),
            size: try cursor.getLongOptional(name: "size")?.int64Value,
        )
    }
}

