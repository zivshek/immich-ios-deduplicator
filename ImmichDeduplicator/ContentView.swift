import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = DuplicateCoordinator()
    @State private var isShowingCleanupConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Immich") {
                    TextField("Server URL", text: $coordinator.serverURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    SecureField("API key", text: $coordinator.apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Status") {
                    HStack {
                        Text(coordinator.statusText)
                        if coordinator.isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }

                Section("Scan Result") {
                    metricRow("Duplicate groups", coordinator.plan.totalDuplicateGroups)
                    metricRow("Immich duplicate groups", coordinator.plan.totalServerDuplicateGroups)
                    metricRow("Immich duplicate assets", coordinator.plan.totalServerDuplicateAssets)
                    metricRow("Local Photos scanned", coordinator.plan.totalLocalAssetCount)
                    metricRow("Local assets to delete", coordinator.plan.localAssetsToDelete)
                    metricRow("Immich assets to remove", coordinator.plan.serverAssetsToRemove)

                    if coordinator.plan.skippedServerTrashAssets > 0 {
                        metricRow("Unmatched server losers", coordinator.plan.skippedServerTrashAssets)
                    }
                }

                if coordinator.lastDeletedLocalCount > 0 || coordinator.lastResolvedServerGroupCount > 0 {
                    Section("Last Cleanup") {
                        metricRow("Deleted local assets", coordinator.lastDeletedLocalCount)
                        metricRow("Resolved Immich groups", coordinator.lastResolvedServerGroupCount)
                    }
                }

                Section {
                    Button {
                        Task { await coordinator.scan() }
                    } label: {
                        Label("Scan Duplicates", systemImage: "magnifyingglass")
                    }
                    .disabled(!coordinator.canScan)

                    Button(role: .destructive) {
                        isShowingCleanupConfirmation = true
                    } label: {
                        Label("Keep Larger for All", systemImage: "trash")
                    }
                    .disabled(!coordinator.canClean)
                }
            }
            .navigationTitle("Immich Dedupe")
            .alert("Cleanup duplicates?", isPresented: $isShowingCleanupConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Smaller Copies", role: .destructive) {
                    Task { await coordinator.clean() }
                }
            } message: {
                Text("iOS will show a Photos deletion prompt. The app deletes local assets first, then resolves duplicate groups on Immich.")
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {
                    coordinator.errorMessage = nil
                }
            } message: {
                Text(coordinator.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.errorMessage = nil } }
        )
    }

    private func metricRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
