import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.startupState {
            case .loading:
                ProgressView("Preparing your photo library…")
            case let .failed(startupError):
                NavigationStack {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Photo library unavailable",
                            systemImage: "externaldrive.badge.exclamationmark",
                            description: Text(startupError)
                        )
                        NavigationLink {
                            DiagnosticsView(store: model.diagnostics)
                        } label: {
                            Label("Open Diagnostics", systemImage: "stethoscope")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .ready:
                if let coordinator = model.coordinator {
                    MainAppShell(model: model, coordinator: coordinator)
                } else {
                    ContentUnavailableView("App unavailable", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .alert(
            "MB Photos",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

private enum TransferAppRoute: Hashable {
    case settings
}

private enum MainAppTab: Hashable {
    case transfer
    case organize
}

private struct MainAppShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var coordinator: ExportCoordinator
    @State private var selectedTab: MainAppTab = .organize
    @State private var transferPath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                OrganizeView(model: model.organizeViewModel)
            }
            .tabItem {
                Label("Organize", systemImage: "rectangle.3.group")
            }
            .tag(MainAppTab.organize)

            NavigationStack(path: $transferPath) {
                TransferHomeView(model: model, coordinator: coordinator)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink(value: TransferAppRoute.settings) {
                                Image(systemName: "gearshape")
                            }
                            .accessibilityLabel("Settings")
                        }
                    }
                    .navigationDestination(for: TransferAppRoute.self) { route in
                        switch route {
                        case .settings:
                            SettingsHubView(
                                model: model,
                                coordinator: coordinator,
                                returnHome: returnToTransfer
                            )
                        }
                    }
            }
            .tabItem {
                Label("Transfer", systemImage: "arrow.up.circle")
            }
            .tag(MainAppTab.transfer)
        }
        .task {
            if model.authorization == .notDetermined {
                await model.authorizeAndLoad()
            } else {
                await model.refreshLibrary()
            }
            await model.refreshHistory()
        }
        .onChange(of: model.catalog.catalogRevision) { _, _ in
            Task { await model.refreshLibrary() }
        }
        .onChange(of: coordinator.progress.phase) { _, phase in
            if TransferPresentationPolicy.clearsQuickSelection(after: phase) {
                model.clearSelectedItems()
            }
            if phase == .completed || phase == .completedWithFailures
                || phase == .failed || phase == .paused {
                Task { await model.refreshHistory() }
            }
        }
    }

    private func returnToTransfer() {
        selectedTab = .transfer
        transferPath = NavigationPath()
    }
}

struct TransferSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
