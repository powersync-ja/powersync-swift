import PowerSync
import SwiftUI

struct StatusIndicatorView<Content: View>: View {
    @Environment(ViewModels.self) var viewModels

    var powerSync: PowerSyncDatabaseProtocol {
        viewModels.databases.powerSync
    }

    @State var statusImageName: String = "wifi.slash"
    @State private var showErrorAlert = false

    let content: () -> Content

    var body: some View {
        content()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if powerSync.currentStatus.anyError != nil {
                            showErrorAlert = true
                        }
                    } label: {
                        Image(systemName: statusImageName)
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
            .alert(isPresented: $showErrorAlert) {
                Alert(
                    title: Text("Error"),
                    message: Text(String("\(powerSync.currentStatus.anyError ?? "Unknown error")")),
                    dismissButton: .default(Text("OK"))
                )
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
                    }
                } catch {
                    print("Could not monitor status")
                }
            }
    }
}
