import PowerSync
import SwiftUI

struct StatusIndicatorView<Content: View>: View {
    @Environment(ViewModels.self) var viewModels

    var powerSync: PowerSyncDatabaseProtocol {
        viewModels.databases.powerSync
    }

    @State var statusImageName: String = "wifi.slash"
    @State var directionStatusImageName: String?

    let content: () -> Content

    var body: some View {
        content()
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        if let error = powerSync.currentStatus.anyError {
                            viewModels.errorViewModel.report("\(error)")
                        }
                    } label: {
                        ZStack {
                            // Network status
                            Image(systemName: statusImageName)
                            // Upload/Download status
                            if let name = directionStatusImageName {
                                Image(systemName: name)
                            }
                        }
                    }
                    .contextMenu {
                        if powerSync.currentStatus.connected || powerSync.currentStatus.connecting {
                            Button("Disconnect") {
                                Task {
                                    try await powerSync.disconnect()
                                }
                            }
                        } else {
                            Button("Connect") {
                                Task {
                                    try await powerSync.connect(
                                        connector: SupabaseConnector(supabase: viewModels.supabaseViewModel)
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .task {
                do {
                    for try await status in powerSync.currentStatus.asFlow() {
                        if powerSync.currentStatus.anyError != nil {
                            statusImageName = "exclamationmark.triangle.fill"
                        } else if status.connected {
                            statusImageName = "wifi"
                        } else if status.connecting {
                            statusImageName = "wifi.exclamationmark"
                        } else {
                            statusImageName = "wifi.slash"
                        }

                        if status.downloading {
                            directionStatusImageName = "chevron.down.2"
                        } else if status.uploading {
                            directionStatusImageName = "chevron.up.2"
                        } else {
                            directionStatusImageName = nil
                        }
                    }
                } catch {
                    print("Could not monitor status")
                }
            }
    }
}
