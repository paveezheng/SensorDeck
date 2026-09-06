// StandBy 卡片：电压 / 电流 / 功耗 / 系统热状态。只读 App Group。

import SwiftUI
import WidgetKit

struct SensorDeckEntry: TimelineEntry {
    let date: Date
    let voltageLine: String
    let currentLine: String
    let powerLine: String
    let thermalLine: String
    let thermalState: String
    let isStale: Bool

    static func make(now: Date, snapshot: SharedSensorSnapshot?, isPreview: Bool) -> SensorDeckEntry {
        if isPreview {
            return SensorDeckEntry(
                date: now,
                voltageLine: "14.80 V",
                currentLine: "+0.99 A",
                powerLine: "14.7 W",
                thermalLine: "Nominal",
                thermalState: "nominal",
                isStale: false
            )
        }

        guard let snapshot else {
            return SensorDeckEntry(
                date: now,
                voltageLine: "— V",
                currentLine: "— A",
                powerLine: "— W",
                thermalLine: "—",
                thermalState: "unknown",
                isStale: true
            )
        }

        let voltage: String = {
            if let value = snapshot.voltageVolts {
                return String(format: "%.2f V", value)
            }
            return "— V"
        }()
        let current: String = {
            if let value = snapshot.currentAmps {
                return String(format: "%+.2f A", value)
            }
            return "— A"
        }()
        let power: String = {
            if let value = snapshot.powerWatts {
                return String(format: "%.1f W", value)
            }
            return "— W"
        }()
        let thermalTitle = snapshot.thermalState.prefix(1).uppercased()
            + snapshot.thermalState.dropFirst()
        return SensorDeckEntry(
            date: now,
            voltageLine: voltage,
            currentLine: current,
            powerLine: power,
            thermalLine: thermalTitle.isEmpty ? "—" : String(thermalTitle),
            thermalState: snapshot.thermalState,
            isStale: snapshot.isStale
        )
    }

    static var placeholder: SensorDeckEntry {
        make(now: Date(), snapshot: nil, isPreview: true)
    }
}

struct SensorDeckProvider: TimelineProvider {
    func placeholder(in context: Context) -> SensorDeckEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (SensorDeckEntry) -> Void) {
        completion(SensorDeckEntry.make(now: Date(), snapshot: SharedSensorSnapshot.loadFromAppGroup(), isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SensorDeckEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedSensorSnapshot.loadFromAppGroup()
        let entry = SensorDeckEntry.make(now: now, snapshot: snapshot, isPreview: context.isPreview)
        // StandBy 锁屏时 App 不在前台；请求约 30 秒后再拉一次快照。
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30))))
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
            Text(entry.voltageLine)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(entry.currentLine)
                .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(secondaryText)
                .lineLimit(1)
            Text(entry.powerLine)
                .font(.system(size: 16, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(secondaryText)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(entry.thermalLine)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(thermalColor)
                if entry.isStale {
                    Text("STALE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryText)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(4)
        .foregroundStyle(primaryText)
        .widgetAccentable()
        .containerBackground(for: .widget) {
            background
        }
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
        voltageLine: "— V",
        currentLine: "— A",
        powerLine: "— W",
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
