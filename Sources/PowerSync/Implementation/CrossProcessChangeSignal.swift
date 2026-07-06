import Foundation
import notify

/// Cross-process change signaling for a database file, built on Darwin notifications —
/// the same mechanism Core Data uses for its remote-change notifications.
///
/// PowerSync's update hooks only observe writes made through the local connection pool.
/// When several processes share a database file (an app and its widgets or App Intents
/// extensions), each process posts this signal after committing a write; the others
/// re-emit their `tableUpdates` with ``EXTERNAL_CHANGES_MARKER`` so `watch` queries
/// re-run and the upload client checks `ps_crud`.
///
/// Darwin notifications carry no payload and are coalesced under pressure, which is fine:
/// the marker means "something changed, re-query". Deliveries to the posting process
/// itself are not suppressed — a redundant re-query (already throttled) is preferable to
/// the race a sender-stamp suppression scheme introduces, where an external change could
/// be misattributed and silently dropped.
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

    /// Starts listening; `onExternalChange` runs on a private queue for every signal
    /// (including this process's own posts).
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

    /// Posts the signal; called after every committed write.
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
