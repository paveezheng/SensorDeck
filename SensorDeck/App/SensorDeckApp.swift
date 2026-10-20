// SwiftUI App 入口：前台采样；充电锁屏时尽量继续写快照给 StandBy。
// 横屏进 Deck 常亮模式（DeckMode 管 isIdleTimerDisabled）。

import SwiftUI

@main
struct SensorDeckApp: App {
    @State private var store = ThermalStore.shared
    @State private var deck = DeckMode.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ThermalStore.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(deck)
                .preferredColorScheme(.dark)
                .onAppear {
                    store.handleScenePhase(.active)
                    deck.handleScenePhase(.active)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            store.handleScenePhase(phase)
            deck.handleScenePhase(phase)
        }
    }
}
