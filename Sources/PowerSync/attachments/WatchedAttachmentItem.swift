
import Combine
import Foundation

/// A watched attachment record item.
/// This is usually returned from watching all relevant attachment IDs.
public struct WatchedAttachmentItem: Sendable {
    /// Id for the attachment record
    public let id: String

    /// File extension used to determine an internal filename for storage if no `filename` is provided
    public let fileExtension: String?

    /// Filename to store the attachment with
    public let filename: String?

    /// Metadata for the attachment (optional)
    public let metaData: String?

    /// Initializes a new `WatchedAttachmentItem`
    /// - Parameters:
    ///   - id: Attachment record ID
    ///   - fileExtension: Optional file extension
    ///   - filename: Optional filename
    ///   - metaData: Optional metadata
    public init(
        id: String,
        fileExtension: String? = nil,
        filename: String? = nil,
        metaData: String? = nil
    ) {
        self.id = id
        self.fileExtension = fileExtension
        self.filename = filename
        self.metaData = metaData

        precondition(fileExtension != nil || filename != nil, "Either fileExtension or filename must be provided.")
    }
}
