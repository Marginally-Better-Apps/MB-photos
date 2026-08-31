import SwiftUI

@main
struct MBPhotosApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: AppModel

    init() {
        _ = CrashLogStore.shared
        BackgroundWorkController.shared.register()
        let model = AppModel()
        BackgroundWorkController.shared.attach(model: model)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )) { _ in
                    model.diagnostics.record(
                        .warning,
                        category: "Memory",
                        message: "iOS issued a memory warning"
                    )
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name.NSProcessInfoPowerStateDidChange
                )) { _ in
                    model.backgroundExecutionConstraintsDidChange()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: ProcessInfo.thermalStateDidChangeNotification
                )) { _ in
                    model.backgroundExecutionConstraintsDidChange()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.sceneDidBecomeActive()
            case .inactive:
                break
            case .background:
                model.sceneDidEnterBackground()
            @unknown default:
                break
            }
        }
    }
}
