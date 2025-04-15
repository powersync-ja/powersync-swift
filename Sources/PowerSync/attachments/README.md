# PowerSync Attachment Helpers

A [PowerSync](https://powersync.com) library to manage attachments in Swift apps.

This package is included in the PowerSync Core module.

## Alpha Release

Attachment helpers are currently in an alpha state, intended strictly for testing. Expect breaking changes and instability as development continues.

Do not rely on this package for production use.

## Usage

An `AttachmentQueue` is used to manage and sync attachments in your app. The attachments' state is stored in a local-only attachments table.

### Key Assumptions

- Each attachment should be identifiable by a unique ID.
- Attachments are immutable.
- Relational data should contain a foreign key column that references the attachment ID.
- Relational data should reflect the holistic state of attachments at any given time. An existing local attachment will be deleted locally if no relational data references it.

### Example

See the [PowerSync Example Demo](../../../Demo/PowerSyncExample) for a basic example of attachment syncing.

In this example, the user captures photos when checklist items are completed as part of an inspection workflow.

The schema for the `checklist` table:

```swift
let checklists = Table(
    name: "checklists",
    columns: [
        Column.text("description"),
        Column.integer("completed"),
        Column.text("photo_id"),
    ]
)

let schema = Schema(
    tables: [
        checklists,
        createAttachmentTable(name: "attachments") // Includes the table which stores attachment states
    ]
)
```

The `createAttachmentTable` function defines the local-only attachment state storage table.

An attachments table definition can be created with the following options:

| Option | Description           | Default       |
| ------ | --------------------- | ------------- |
| `name` | The name of the table | `attachments` |

The default columns in `AttachmentTable`:

| Column Name  | Type      | Description                                                                                                        |
| ------------ | --------- | ------------------------------------------------------------------------------------------------------------------ |
| `id`         | `TEXT`    | The ID of the attachment record                                                                                    |
| `filename`   | `TEXT`    | The filename of the attachment                                                                                     |
| `media_type` | `TEXT`    | The media type of the attachment                                                                                   |
| `state`      | `INTEGER` | The state of the attachment, one of `AttachmentState` enum values                                                  |
| `timestamp`  | `INTEGER` | The timestamp of the last update to the attachment record                                                          |
| `size`       | `INTEGER` | The size of the attachment in bytes                                                                                |
| `has_synced` | `INTEGER` | Internal tracker which tracks if the attachment has ever been synced. This is used for caching/archiving purposes. |
| `meta_data`  | `TEXT`    | Any extra meta data for the attachment. JSON is usually a good choice.                                             |

#### Steps to Implement

1. Implement a `RemoteStorageAdapter` which interfaces with a remote storage provider. This will be used for downloading, uploading, and deleting attachments.

```swift
class RemoteStorage: RemoteStorageAdapter {
    func uploadFile(data: Data, attachment: Attachment) async throws {
        // TODO: Make a request to the backend
    }

    func downloadFile(attachment: Attachment) async throws -> Data {
        // TODO: Make a request to the backend
    }

    func deleteFile(attachment: Attachment) async throws {
        // TODO: Make a request to the backend
    }
}
```

2. Create an instance of `AttachmentQueue`. This class provides default syncing utilities and implements a default sync strategy. It can be subclassed for custom functionality.

```swift
func getAttachmentsDirectoryPath() throws -> String {
    guard let documentsURL = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    ).first else {
        throw PowerSyncAttachmentError.attachmentError("Could not determine attachments directory path")
    }
    return documentsURL.appendingPathComponent("attachments").path
}

let queue = AttachmentQueue(
    db: db,
    attachmentsDirectory: try getAttachmentsDirectoryPath(),
    remoteStorage: RemoteStorage(),
    watchedAttachments: try db.watch(
        options: WatchOptions(
            sql: "SELECT photo_id FROM checklists WHERE photo_id IS NOT NULL",
            parameters: [],
            mapper: { cursor in
                try WatchedAttachmentItem(
                    id: cursor.getString(name: "photo_id"),
                    fileExtension: "jpg"
                )
            }
        )
    )
)
```

- The `attachmentsDirectory` specifies where local attachment files should be stored. `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("attachments")` is a good choice.
- The `remoteStorage` is responsible for connecting to the attachments backend. See the `RemoteStorageAdapter` protocol definition.
- `watchedAttachments` is a publisher of `WatchedAttachmentItem`. These items represent the attachments that should be present in the application.

3. Call `startSync()` to start syncing attachments.

```swift
queue.startSync()
```

4. To create an attachment and add it to the queue, call `saveFile()`. This method saves the file to local storage, creates an attachment record, queues the file for upload, and allows assigning the newly created attachment ID to a checklist item.

```swift
try await queue.saveFile(
    data: Data(), // The attachment's data
    mediaType: "image/jpg",
    fileExtension: "jpg"
) { tx, attachment in
    // Assign the attachment ID to a checklist item in the same transaction
    try tx.execute(
        sql: """
            UPDATE
                checklists
            SET
                photo_id = ?
            WHERE
                id = ?
            """,
        arguments: [attachment.id, checklistId]
    )
}
```

#### Handling Errors

The attachment queue automatically retries failed sync operations. Retries continue indefinitely until success. A `SyncErrorHandler` can be provided to the `AttachmentQueue` constructor. This handler provides methods invoked on a remote sync exception. The handler can return a Boolean indicating if the attachment sync should be retried or archived.

```swift
class ErrorHandler: SyncErrorHandler {
    func onDownloadError(attachment: Attachment, error: Error) async -> Bool {
        // TODO: Return if the attachment sync should be retried
    }

    func onUploadError(attachment: Attachment, error: Error) async -> Bool {
        // TODO: Return if the attachment sync should be retried
    }

    func onDeleteError(attachment: Attachment, error: Error) async -> Bool {
        // TODO: Return if the attachment sync should be retried
    }
}

// Pass the handler to the queue constructor
let queue = AttachmentQueue(
    db: db,
    attachmentsDirectory: attachmentsDirectory,
    remoteStorage: remoteStorage,
    errorHandler: ErrorHandler()
)
```

## Implementation Details

### Attachment State

The `AttachmentQueue` class manages attachments in your app by tracking their state.

The state of an attachment can be one of the following:

| State             | Description                                                                    |
| ----------------- | ------------------------------------------------------------------------------ |
| `QUEUED_UPLOAD`   | The attachment has been queued for upload to the cloud storage                 |
| `QUEUED_DELETE`   | The attachment has been queued for delete in the cloud storage (and locally)   |
| `QUEUED_DOWNLOAD` | The attachment has been queued for download from the cloud storage             |
| `SYNCED`          | The attachment has been synced                                                 |
| `ARCHIVED`        | The attachment has been orphaned, i.e., the associated record has been deleted |

### Syncing Attachments

The `AttachmentQueue` sets a watched query on the `attachments` table for records in the `QUEUED_UPLOAD`, `QUEUED_DELETE`, and `QUEUED_DOWNLOAD` states. An event loop triggers calls to the remote storage for these operations.

In addition to watching for changes, the `AttachmentQueue` also triggers a sync periodically. This will retry any failed uploads/downloads, particularly after the app was offline. By default, this is every 30 seconds but can be configured by setting `syncInterval` in the `AttachmentQueue` constructor options or disabled by setting the interval to `0`.

#### Watching State

The `watchedAttachments` publisher provided to the `AttachmentQueue` constructor is used to reconcile the local attachment state. Each emission of the publisher should represent the current attachment state. The updated state is constantly compared to the current queue state. Items are queued based on the difference.

- A new watched item not present in the current queue is treated as an upstream attachment creation that needs to be downloaded.
  - An attachment record is created using the provided watched item. The filename will be inferred using a default filename resolver if it has not been provided in the watched item.
  - The syncing service will attempt to download the attachment from the remote storage.
  - The attachment will be saved to the local filesystem. The `localURI` on the attachment record will be updated.
  - The attachment state will be updated to `SYNCED`.
- Local attachments are archived if the watched state no longer includes the item. Archived items are cached and can be restored if the watched state includes them in the future. The number of cached items is defined by the `archivedCacheLimit` parameter in the `AttachmentQueue` constructor. Items are deleted once the cache limit is reached.

#### Uploading

The `saveFile` method provides a simple method for creating attachments that should be uploaded to the backend. This method accepts the raw file content and metadata. This function:

- Persists the attachment to the local filesystem.
- Creates an attachment record linked to the local attachment file.
- Queues the attachment for upload.
- Allows assigning the attachment to relational data.

The sync process after calling `saveFile` is:

- An `AttachmentRecord` is created or updated with a state of `QUEUED_UPLOAD`.
- The `RemoteStorageAdapter` `uploadFile` function is called with the `Attachment` record.
- The `AttachmentQueue` picks this up and, upon successful upload to the remote storage, sets the state to `SYNCED`.
- If the upload is not successful, the record remains in the `QUEUED_UPLOAD` state, and uploading will be retried when syncing triggers again. Retries can be stopped by providing an `errorHandler`.

#### Downloading

Attachments are scheduled for download when the `watchedAttachments` publisher emits a `WatchedAttachmentItem` not present in the queue.

- An `AttachmentRecord` is created or updated with the `QUEUED_DOWNLOAD` state.
- The `RemoteStorageAdapter` `downloadFile` function is called with the attachment record.
- The received data is persisted to the local filesystem.
- If this is successful, update the `AttachmentRecord` state to `SYNCED`.
- If any of these fail, the download is retried in the next sync trigger.

#### Deleting Attachments

Local attachments are archived and deleted (locally) if the `watchedAttachments` publisher no longer references them. Archived attachments are deleted locally after cache invalidation.

In some cases, users might want to explicitly delete an attachment in the backend. The `deleteFile` function provides a mechanism for this. This function:

- Deletes the attachment on the local filesystem.
- Updates the record to the `QUEUED_DELETE` state.
- Allows removing assignments to relational data.

#### Expire Cache

When PowerSync removes a record, as a result of coming back online or conflict resolution, for instance:

- Any associated `AttachmentRecord` is orphaned.
- On the next sync trigger, the `AttachmentQueue` sets all orphaned records to the `ARCHIVED` state.
- By default, the `AttachmentQueue` only keeps the last `100` attachment records and then expires the rest.
- In some cases, these records (attachment IDs) might be restored. An archived attachment will be restored if it is still in the cache. This can be configured by setting `cacheLimit` in the `AttachmentQueue` constructor options.
