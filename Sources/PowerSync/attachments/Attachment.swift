/// Enum representing the state of an attachment
public enum AttachmentState: Int {
    /// The attachment has been queued for download from the cloud storage
    case queuedDownload
    /// The attachment has been queued for upload to the cloud storage
    case queuedUpload
    /// The attachment has been queued for delete in the cloud storage (and locally)
    case queuedDelete
    /// The attachment has been synced
    case synced
    /// The attachment has been orphaned, i.e., the associated record has been deleted
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
    public let hasSynced: Bool?

    /// Extra attachment metadata
    public let metaData: String?

    /// Initializes a new `Attachment` instance
    public init(
        id: String,
        filename: String,
        state: AttachmentState,
        timestamp: Int = 0,
        hasSynced: Bool? = false,
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
        state: AttachmentState? = nil,
        timestamp : Int = 0,
        hasSynced: Bool? = nil,
        localUri: String?? = .none,
        mediaType: String?? = .none,
        size: Int64?? = .none,
        metaData: String?? = .none
    ) -> Attachment {
        return Attachment(
            id: id,
            filename: filename ?? self.filename,
            state: state ?? self.state,
            timestamp: timestamp > 0 ? timestamp : self.timestamp,
            hasSynced: hasSynced ?? self.hasSynced,
            localUri: resolveOverride(localUri, current: self.localUri),
            mediaType: resolveOverride(mediaType, current: self.mediaType),
            size: resolveOverride(size, current: self.size),
            metaData: resolveOverride(metaData, current: self.metaData)
        )
    }
    
    /// Resolves double optionals
    /// if a non nil value is provided: the override will be used
    /// if .some(nil) is provided: The value will be set to nil
    /// // if nil is provided:  the current value will be preserved
    private func resolveOverride<T>(_ override: T??, current: T?) -> T? {
        if let value = override {
            return value  // could be nil (explicit clear) or a value
        } else {
            return current  // not provided, use current
        }
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
            state: AttachmentState.from(cursor.getInt(name: "state")),
            timestamp: cursor.getInt(name: "timestamp"),
            hasSynced: cursor.getInt(name: "has_synced") > 0,
            localUri: cursor.getStringOptional(name: "local_uri"),
            mediaType: cursor.getStringOptional(name: "media_type"),
            size: cursor.getInt64Optional(name: "size"),
            metaData: cursor.getStringOptional(name: "meta_data")
        )
    }
}
