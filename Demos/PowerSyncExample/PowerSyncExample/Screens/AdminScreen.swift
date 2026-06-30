import PowerSync
import SwiftUI

struct AdminScreen: View {
    @Environment(SystemManager.self) private var system

    @State private var status: SyncStatusData?
    @State private var actionInProgress: String?
    @State private var actionMessage: String?
    @State private var actionError: Error?

    var body: some View {
        List {
            Section("Actions") {
                Button {
                    runAction("Disconnect") {
                        try await system.disconnect()
                    }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .disabled(actionInProgress != nil)

                Button {
                    runAction("Connect") {
                        try await system.connectAndWaitForStatus()
                    }
                } label: {
                    Label("Connect", systemImage: "bolt")
                }
                .disabled(actionInProgress != nil)

                Button {
                    runAction("Connect and Wait For Sync") {
                        try await system.connectAndSync()
                    }
                } label: {
                    Label("Connect and Wait For Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(actionInProgress != nil)

                if let actionInProgress {
                    HStack {
                        ProgressView()
                        Text(actionInProgress)
                    }
                }

                if let actionMessage {
                    Text(actionMessage)
                        .foregroundStyle(.secondary)
                }

                if let actionError {
                    Text(actionError.localizedDescription)
                        .foregroundStyle(.red)
                }
            }

            Section("Status") {
                if let status {
                    statusRow("Connected", bool(status.connected))
                    statusRow("Connecting", bool(status.connecting))
                    statusRow("Downloading", bool(status.downloading))
                    statusRow("Uploading", bool(status.uploading))
                    statusRow("Has synced", optionalBool(status.hasSynced))
                    statusRow("Last synced", format(status.lastSyncedAt))
                    statusRow("Last applied checkpoint request ID", format(status.lastAppliedCheckpointRequestId))

                    if let progress = status.downloadProgress {
                        VStack(alignment: .leading, spacing: 8) {
                            statusRow("Download progress", progressText(progress))
                            ProgressView(value: Double(progress.fraction))
                        }
                    }
                } else {
                    ProgressView()
                }
            }

            if let status, hasErrors {
                Section("Errors") {
                    if let downloadError = status.downloadError {
                        statusRow("Download", String(describing: downloadError))
                    }

                    if let uploadError = status.uploadError {
                        statusRow("Upload", String(describing: uploadError))
                    }
                }
            }

            if let priorityStatusEntries = status?.priorityStatusEntries, !priorityStatusEntries.isEmpty {
                Section("Priorities") {
                    ForEach(Array(priorityStatusEntries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Priority \(entry.priority.priorityCode)")
                                .font(.headline)
                            statusRow("Has synced", optionalBool(entry.hasSynced))
                            statusRow("Last synced", format(entry.lastSyncedAt))
                        }
                    }
                }
            }

            if let syncStreams = status?.syncStreams, !syncStreams.isEmpty {
                Section("Streams") {
                    ForEach(Array(syncStreams.enumerated()), id: \.offset) { _, stream in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(stream.subscription.name)
                                .font(.headline)
                            statusRow("Active", bool(stream.subscription.active))
                            statusRow("Default", bool(stream.subscription.isDefault))
                            statusRow("Explicit", bool(stream.subscription.hasExplicitSubscription))
                            statusRow("Has synced", bool(stream.subscription.hasSynced))
                            statusRow("Last synced", formatUnixTime(stream.subscription.lastSyncedAt))
                            statusRow("Expires", formatUnixTime(stream.subscription.expiresAt))

                            if let parameters = stream.subscription.parameters {
                                statusRow("Parameters", String(describing: parameters))
                            }

                            if let progress = stream.progress {
                                statusRow("Progress", progressText(progress))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Admin")
        .task {
            status = system.db.currentStatus

            for await update in system.db.currentStatus.asFlow() {
                status = update
            }
        }
    }

    private var hasErrors: Bool {
        status?.downloadError != nil || status?.uploadError != nil
    }

    private func runAction(_ title: String, action: @escaping () async throws -> Void) {
        actionInProgress = title
        actionMessage = nil
        actionError = nil

        Task { @MainActor in
            do {
                try await action()
                actionMessage = "\(title) complete"
            } catch {
                actionError = error
            }

            actionInProgress = nil
        }
    }

    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func bool(_ value: Bool) -> String {
        return value ? "Yes" : "No"
    }

    private func optionalBool(_ value: Bool?) -> String {
        guard let value else {
            return "Unknown"
        }

        return bool(value)
    }

    private func format(_ date: Date?) -> String {
        guard let date else {
            return "Never"
        }

        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func format(_ value: Int64?) -> String {
        guard let value else {
            return "None"
        }

        return String(value)
    }

    private func formatUnixTime(_ time: TimeInterval?) -> String {
        guard let time else {
            return "None"
        }

        return format(Date(timeIntervalSince1970: time))
    }

    private func progressText(_ progress: any ProgressWithOperations) -> String {
        let percent = Int((progress.fraction * 100).rounded())
        return "\(progress.downloadedOperations)/\(progress.totalOperations) (\(percent)%)"
    }
}

#Preview {
    NavigationStack {
        AdminScreen()
            .environment(SystemManager())
    }
}
