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
    
    enum AttachmentStateError: Error {
        case invalidState(Int)
    }
    
    static func from(_ rawValue: Int) throws -> AttachmentState {
        guard let state = AttachmentState(rawValue: rawValue) else {
            throw AttachmentStateError.invalidState(rawValue)
        }
        return state
    }
}

/// Struct representing an attachment
public struct Attachment {
    /// Unique identifier for the attachment
    public let id: String

    /// Timestamp for the last record update
    public let timestamp: Int

    /// Attachment filename, e.g. `[id].jpg`
    public let filename: String

    /// Current attachment state
    public let state: AttachmentState

    /// Local URI pointing to the attachment file
    public let localUri: String?

    /// Attachment media type (usually a MIME type)
    public let mediaType: String?

    /// Attachment byte size
    public let size: Int64?

    /// Specifies if the attachment has been synced locally before.
    /// This is particularly useful for restoring archived attachments in edge cases.
    public let hasSynced: Int?

    /// Extra attachment metadata
    public let metaData: String?

    /// Initializes a new `Attachment` instance
    public init(
        id: String,
        filename: String,
        state: AttachmentState,
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
        filename _: String? = nil,
        state: AttachmentState? = nil,
        timestamp _: Int = 0,
        hasSynced: Int? = 0,
        localUri: String? = nil,
        mediaType: String? = nil,
        size: Int64? = nil,
        metaData: String? = nil
    ) -> Attachment {
        return Attachment(
            id: id,
            filename: filename,
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
        return try Attachment(
            id: cursor.getString(name: "id"),
            filename: cursor.getString(name: "filename"),
            state: AttachmentState.from(cursor.getLong(name: "state")),
            timestamp: cursor.getLong(name: "timestamp"),
            hasSynced: cursor.getLongOptional(name: "has_synced"),
            localUri: cursor.getStringOptional(name: "local_uri"),
            mediaType: cursor.getStringOptional(name: "media_type"),
            size: cursor.getLongOptional(name: "size")?.int64Value,
            metaData: cursor.getStringOptional(name: "meta_data")
        )
    }
}
