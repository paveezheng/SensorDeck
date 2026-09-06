// Widget Extension 入口。只注册 StandBy 小组件。

import WidgetKit
import SwiftUI

@main
struct SensorDeckWidgetBundle: WidgetBundle {
    var body: some Widget {
        SensorDeckWidget()
    }
}
