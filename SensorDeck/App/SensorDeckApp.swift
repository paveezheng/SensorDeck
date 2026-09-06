// SwiftUI App 入口：前台采样；充电锁屏时尽量继续写快照给 StandBy。

import SwiftUI

@main
struct SensorDeckApp: App {
    @State private var store = ThermalStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ThermalStore.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(store)
                .preferredColorScheme(.dark)
                .onAppear {
                    store.handleScenePhase(.active)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            store.handleScenePhase(phase)
        }
    }
}
