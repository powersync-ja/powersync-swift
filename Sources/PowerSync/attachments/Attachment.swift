/// Enum representing the state of an attachment
public enum AttachmentState: Int {
    /// The attachment is queued for download
    case queuedDownload
    /// The attachment is queued for upload
    case queuedUpload
    /// The attachment is queued for deletion
    case queuedDelete
    /// The attachment is fully synced
    case synced
    /// The attachment is archived
    case archived
}

/// Struct representing an attachment
public struct Attachment {
    /// Unique identifier for the attachment
    let id: String

    /// Timestamp for the last record update
    let timestamp: Int

    /// Attachment filename, e.g. `[id].jpg`
    let filename: String

    /// Current attachment state, represented by the raw value of `AttachmentState`
    let state: Int

    /// Local URI pointing to the attachment file
    let localUri: String?

    /// Attachment media type (usually a MIME type)
    let mediaType: String?

    /// Attachment byte size
    let size: Int64?

    /// Specifies if the attachment has been synced locally before.
    /// This is particularly useful for restoring archived attachments in edge cases.
    let hasSynced: Int?

    /// Extra attachment metadata
    let metaData: String?

    /// Initializes a new `Attachment` instance
    public init(
        id: String,
        filename: String,
        state: Int,
        timestamp: Int = 0,
        hasSynced: Int? = 0,
        localUri: String? = nil,
        mediaType: String? = nil,
        size: Int64? = nil,
        metaData: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.filename = filename
        self.state = state
        self.localUri = localUri
        self.mediaType = mediaType
        self.size = size
        self.hasSynced = hasSynced
        self.metaData = metaData
    }

    /// Returns a new `Attachment` instance with the option to override specific fields.
    ///
    /// - Parameters:
    ///   - filename: Optional new filename.
    ///   - state: Optional new state.
    ///   - timestamp: Optional new timestamp.
    ///   - hasSynced: Optional new `hasSynced` flag.
    ///   - localUri: Optional new local URI.
    ///   - mediaType: Optional new media type.
    ///   - size: Optional new size.
    ///   - metaData: Optional new metadata.
    /// - Returns: A new `Attachment` with updated values.
    func with(
        filename: String? = nil,
        state: Int? = nil,
        timestamp: Int = 0,
        hasSynced: Int? = 0,
        localUri: String? = nil,
        mediaType: String? = nil,
        size: Int64? = nil,
        metaData: String? = nil
    ) -> Attachment {
        return Attachment(
            id: self.id,
            filename: self.filename,
            state: state ?? self.state,
            hasSynced: hasSynced ?? self.hasSynced,
            localUri: localUri ?? self.localUri,
            mediaType: mediaType ?? self.mediaType,
            size: size ?? self.size,
            metaData: metaData ?? self.metaData
        )
    }

    /// Constructs an `Attachment` from a `SqlCursor`.
    ///
    /// - Parameter cursor: The `SqlCursor` containing the attachment data.
    /// - Throws: If required fields are missing or of incorrect type.
    /// - Returns: A fully constructed `Attachment` instance.
    public static func fromCursor(_ cursor: SqlCursor) throws -> Attachment {
        return Attachment(
            id: try cursor.getString(name: "id"),
            filename: try cursor.getString(name: "filename"),
            state: try cursor.getLong(name: "state"),
            timestamp: try cursor.getLong(name: "timestamp"),
            hasSynced: try cursor.getLongOptional(name: "has_synced"),
            localUri: try cursor.getStringOptional(name: "local_uri"),
            mediaType: try cursor.getStringOptional(name: "media_type"),
            size: try cursor.getLongOptional(name: "size")?.int64Value,
            metaData: try cursor.getStringOptional(name: "meta_data")
        )
    }
}
