import Foundation
import notify

/// Cross-process change transport for a database file, built on Darwin notifications, the
/// same mechanism Core Data uses for its remote-change notifications.
///
/// PowerSync's update hooks only observe writes made through the local connection pool. When
/// several processes share a database file (an app and its widgets or App Intents
/// extensions), each process records the tables it changed in the `ps_swift_updates` table
/// and posts this signal; the others read the new rows and re-emit those tables on their
/// `tableUpdates` so `watch` queries re-run and the upload client checks `ps_crud`.
///
/// Darwin notifications carry no payload and are coalesced under pressure, which is fine:
/// the payload lives in `ps_swift_updates`, and each receiver tracks the highest row id it
/// has consumed. Deliveries to the posting process itself are not suppressed here either; that
/// is handled where the rows are read, by ignoring this process's own `author`, so a process
/// never wakes itself.
final class CrossProcessChangeSignal: @unchecked Sendable {
    private let name: String
    private let logger: any LoggerProtocol
    private var token: Int32 = NOTIFY_TOKEN_INVALID
    private let queue = DispatchQueue(label: "powersync.cross-process-signal")

    init(databasePath: String, logger: any LoggerProtocol) {
        // Stable across processes: both sides derive the name from the canonical path.
        let canonical = URL(fileURLWithPath: databasePath).standardizedFileURL.path
        self.name = "com.powersync.changes.\(Self.fnv1a(canonical))"
        self.logger = logger
    }

    /// Starts listening; `onChange` runs on a private queue for every notification, including
    /// the ones caused by this process's own posts. Callers are expected to throttle it: the
    /// notification carries no information, so handling several of them at once is the same as
    /// handling one.
    func start(onChange: @escaping @Sendable () -> Void) {
        guard token == NOTIFY_TOKEN_INVALID else {
            return
        }
        let status = notify_register_dispatch(name, &token, queue) { _ in
            onChange()
        }
        if status != NOTIFY_STATUS_OK {
            logger.warning(
                "could not register cross-process change signal (status \(status)); "
                    + "changes from other processes will not wake watch queries",
                tag: "CrossProcessChangeSignal"
            )
            token = NOTIFY_TOKEN_INVALID
        }
    }

    /// Posts the signal; called after a write recorded the tables it changed.
    func post() {
        notify_post(name)
    }

    func stop() {
        if token != NOTIFY_TOKEN_INVALID {
            notify_cancel(token)
            token = NOTIFY_TOKEN_INVALID
        }
    }

    deinit {
        stop()
    }

    /// FNV-1a 64-bit, hex-encoded: deterministic and dependency-free.
    private static func fnv1a(_ input: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
