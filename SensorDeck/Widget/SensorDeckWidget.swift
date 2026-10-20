// StandBy 卡片：电压 / 电流 / 功耗 / 系统热状态。只读 App Group。
// 刷新时不做任何动画：字符宽度固定 + contentTransition(.identity)，数字原地替换。

import SwiftUI
import WidgetKit

struct SensorDeckEntry: TimelineEntry {
    let date: Date
    let voltageValue: String
    let currentValue: String
    let powerValue: String
    let thermalLine: String
    let thermalState: String
    let isStale: Bool

    static func make(date: Date, snapshot: SharedSensorSnapshot?, isPreview: Bool) -> SensorDeckEntry {
        if isPreview {
            return SensorDeckEntry(
                date: date,
                voltageValue: "14.80",
                currentValue: "+0.99",
                powerValue: SharedSensorSnapshot.pad("14.7", to: 5),
                thermalLine: "Nominal",
                thermalState: "nominal",
                isStale: false
            )
        }

        guard let snapshot else {
            return .unavailable(date: date)
        }

        return SensorDeckEntry(
            date: date,
            voltageValue: snapshot.voltageText,
            currentValue: snapshot.currentText,
            powerValue: snapshot.powerText,
            thermalLine: snapshot.thermalTitle,
            thermalState: snapshot.thermalState,
            isStale: snapshot.isStale(at: date)
        )
    }

    static func unavailable(date: Date) -> SensorDeckEntry {
        SensorDeckEntry(
            date: date,
            voltageValue: SharedSensorSnapshot.pad("—", to: 5),
            currentValue: SharedSensorSnapshot.pad("—", to: 5),
            powerValue: SharedSensorSnapshot.pad("—", to: 5),
            thermalLine: "—",
            thermalState: "unknown",
            isStale: true
        )
    }

    static var placeholder: SensorDeckEntry {
        make(date: Date(), snapshot: nil, isPreview: true)
    }
}

struct SensorDeckProvider: TimelineProvider {
    func placeholder(in context: Context) -> SensorDeckEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SensorDeckEntry) -> Void) {
        completion(
            SensorDeckEntry.make(
                date: Date(),
                snapshot: SharedSensorSnapshot.loadFromAppGroup(),
                isPreview: context.isPreview
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SensorDeckEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedSensorSnapshot.loadFromAppGroup()
        var entries = [SensorDeckEntry.make(date: now, snapshot: snapshot, isPreview: context.isPreview)]

        // 数值只有 App 在跑的时候才会变，所以不靠 timeline 去"追"新数字；
        // 这里只额外排一条 entry，用来在快照真的过期时点亮 STALE，不用再叫醒一次 WidgetKit。
        if let snapshot, !context.isPreview, snapshot.staleDate > now {
            entries.append(SensorDeckEntry.make(date: snapshot.staleDate, snapshot: snapshot, isPreview: false))
        }

        // App 刚写过快照（说明它还活着）就早点再要一次；否则数字不会变，退到 5 分钟省预算。
        // App 回到前台/后台采样时会主动 reloadTimelines，所以退避不影响响应速度。
        let appLooksAlive = snapshot.map { now.timeIntervalSince($0.updatedAt) < 120 } ?? false
        let nextRefresh = now.addingTimeInterval(appLooksAlive ? 60 : 300)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }
}

struct SensorDeckWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppGroup.widgetKind, provider: SensorDeckProvider()) { entry in
            SensorDeckStandByView(entry: entry)
        }
        .configurationDisplayName("SensorDeck")
        .description("Charging voltage, current, power, and thermal state.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SensorDeckStandByView: View {
    var entry: SensorDeckEntry
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            valueRow(entry.voltageValue, unit: "V", size: 22, weight: .semibold, color: primaryText)
            valueRow(entry.currentValue, unit: "A", size: 16, weight: .medium, color: secondaryText)
            valueRow(entry.powerValue, unit: "W", size: 16, weight: .medium, color: secondaryText)
            thermalRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(4)
        .foregroundStyle(primaryText)
        .widgetAccentable()
        .containerBackground(for: .widget) {
            background
        }
        // 时间线换 entry 时 WidgetKit 默认会做淡入淡出/模糊过渡，看起来就是"抖一下"。
        .transaction { $0.animation = nil }
    }

    private func valueRow(
        _ value: String,
        unit: String,
        size: CGFloat,
        weight: Font.Weight,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
                .contentTransition(.identity)
            Text(unit)
                .font(.system(size: size * 0.72, weight: weight, design: .rounded))
                .foregroundStyle(secondaryText)
                .contentTransition(.identity)
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var thermalRow: some View {
        HStack(spacing: 6) {
            Text(entry.thermalLine)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(thermalColor)
                .contentTransition(.identity)
            Spacer(minLength: 0)
            // 位置常驻，只切换透明度，出现/消失时不会顶动上面的行。
            Text("STALE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(secondaryText)
                .opacity(entry.isStale ? 1 : 0)
        }
        .lineLimit(1)
    }

    private var primaryText: Color {
        switch renderingMode {
        case .accented:
            return .primary
        default:
            return Color(red: 0.98, green: 0.86, blue: 0.72)
        }
    }

    private var secondaryText: Color {
        switch renderingMode {
        case .accented:
            return .secondary
        default:
            return Color(red: 0.78, green: 0.68, blue: 0.56)
        }
    }

    private var thermalColor: Color {
        if renderingMode == .accented {
            return .primary
        }
        switch entry.thermalState {
        case "nominal":
            return Color(red: 0.35, green: 0.82, blue: 0.48)
        case "fair":
            return Color(red: 0.95, green: 0.82, blue: 0.28)
        case "serious":
            return Color(red: 1.0, green: 0.55, blue: 0.22)
        case "critical":
            return Color(red: 1.0, green: 0.32, blue: 0.28)
        default:
            return secondaryText
        }
    }

    @ViewBuilder
    private var background: some View {
        switch renderingMode {
        case .fullColor:
            Color(red: 0.05, green: 0.05, blue: 0.06)
        default:
            Color.clear
        }
    }
}

#Preview("Small", as: .systemSmall) {
    SensorDeckWidget()
} timeline: {
    SensorDeckEntry.placeholder
    SensorDeckEntry(
        date: Date(),
        voltageValue: SharedSensorSnapshot.valueText(9.02, decimals: 2),
        currentValue: SharedSensorSnapshot.valueText(1.2, decimals: 2, signed: true),
        powerValue: SharedSensorSnapshot.valueText(10.8, decimals: 1),
        thermalLine: "Fair",
        thermalState: "fair",
        isStale: true
    )
}

#Preview("Medium", as: .systemMedium) {
    SensorDeckWidget()
} timeline: {
    SensorDeckEntry.placeholder
}
