// 横屏 → Deck 常亮大字；竖屏 → 完整仪表盘（含 HID 列表）。
//
// 用画布尺寸判断横竖屏，不用 UIDevice.orientation：后者跟旋转锁定无关，
// 锁了竖屏时照样报 landscape，会在竖画布上渲染横屏布局。

import SwiftUI

struct RootView: View {
    @Environment(DeckMode.self) private var deck

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            Group {
                if wide {
                    DeckView()
                } else {
                    DashboardView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { deck.updateCanvas(isWide: wide) }
            .onChange(of: wide) { _, isWide in deck.updateCanvas(isWide: isWide) }
        }
    }
}

#Preview {
    RootView()
        .environment(ThermalStore.preview)
        .environment(DeckMode())
        .preferredColorScheme(.dark)
}
