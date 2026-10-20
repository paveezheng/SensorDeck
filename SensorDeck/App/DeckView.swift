// Deck 模式大字读数：横屏放在充电座上当监视器用，1 秒刷新。
// 数字全部定宽（复用 SharedSensorSnapshot 的补位规则）+ monospacedDigit，
// 1Hz 下不重排、不缩放、不做任何过渡动画。

import SwiftUI

struct DeckView: View {
    @Environment(ThermalStore.self) private var store
    @Environment(DeckMode.self) private var deck

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 系统旋转锁定时画布可能仍然是竖的，按真实尺寸决定排版。
            let wide = size.width > size.height
            let unit = min(size.width, size.height)

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(alignment: .leading, spacing: unit * 0.05) {
                    if wide {
                        // 两栏必须按固定比例分宽度。用 Spacer 让它们自己抢的话，
                        // 右栏数值变成 "—" 时会变窄 → 左栏拿到更多空间 →
                        // minimumScaleFactor 把温度重新放大，看起来就是温度在忽大忽小。
                        HStack(alignment: .top, spacing: 0) {
                            hero(unit: unit)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            electricals(unit: unit, alignment: .trailing)
                                .frame(width: size.width * 0.40, alignment: .trailing)
                        }
                    } else {
                        hero(unit: unit)
                        electricals(unit: unit, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    statusStrip(unit: unit)
                }
                .padding(.horizontal, unit * 0.07)
                .padding(.vertical, unit * 0.06)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(deck.burnInOffset)
            }
            // 灵动岛是硬件挖孔 + 系统图层，App 碰不到（SwiftUI 没有任何相关 API）。
            // 能去掉的只有这两层：状态栏和底部 home indicator。
            // home indicator 对常亮屏尤其值得关掉 —— 一条固定白杠挂几小时正是烧屏的形状。
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
        }
    }

    // MARK: - 块

    private func hero(unit: CGFloat) -> some View {
        let heroSize = max(56, min(unit * 0.30, 132))
        return VStack(alignment: .leading, spacing: unit * 0.02) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                let temperature = Self.number(store.reading.batteryCelsius, decimals: 1, width: 4)
                Text(temperature.text)
                    // "—" 在 130pt 下是一条大横杠，缩掉一半才像占位符。
                    .font(.system(
                        size: temperature.isPlaceholder ? heroSize * 0.45 : heroSize,
                        weight: .medium,
                        design: .rounded
                    ).monospacedDigit())
                    .foregroundStyle(temperature.isPlaceholder ? Self.secondary : Self.amber)
                Text("°C")
                    .font(.system(size: heroSize * 0.34, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.amber.opacity(0.7))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            Text(store.reading.batteryCaption)
                .font(.system(size: max(11, min(unit * 0.037, 17)), weight: .medium))
                .foregroundStyle(.secondary)

            thermalPill(unit: unit)
        }
    }

    private func electricals(unit: CGFloat, alignment: HorizontalAlignment) -> some View {
        let valueSize = max(26, min(unit * 0.14, 60))
        return VStack(alignment: alignment, spacing: unit * 0.025) {
            deckValue(
                Self.number(store.reading.voltageVolts, decimals: 2),
                unit: "V",
                size: valueSize,
                color: Self.primary
            )
            deckValue(
                Self.number(store.reading.currentAmps, decimals: 2, signed: true),
                unit: "A",
                size: valueSize,
                color: Self.secondary
            )
            deckValue(
                Self.number(store.reading.powerWatts, decimals: 1),
                unit: "W",
                size: valueSize,
                color: Self.secondary
            )
        }
    }

    private func deckValue(
        _ value: DeckNumber,
        unit label: String,
        size: CGFloat,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.16) {
            Text(value.text)
                .font(.system(
                    size: value.isPlaceholder ? size * 0.6 : size,
                    weight: .semibold,
                    design: .rounded
                ).monospacedDigit())
                .foregroundStyle(value.isPlaceholder ? Self.secondary.opacity(0.6) : color)
            Text(label)
                .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
                .foregroundStyle(Self.secondary.opacity(0.75))
                .frame(width: size * 0.5, alignment: .leading)
        }
        .lineLimit(1)
    }

    private func thermalPill(unit: CGFloat) -> some View {
        Text(store.reading.thermal.title)
            .font(.system(size: max(11, min(unit * 0.036, 16)), weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(store.reading.thermal.color)
            .background(store.reading.thermal.color.opacity(0.16))
            .clipShape(Capsule())
    }

    private func statusStrip(unit: CGFloat) -> some View {
        let size = max(10, min(unit * 0.032, 15))
        return HStack(spacing: unit * 0.045) {
            statusItem("BATT", store.reading.batteryPercentText, size: size)
            statusItem("STATE", store.reading.charging.title, size: size)
            statusItem("CPU", store.reading.cpuPercentText, size: size)
            statusItem("TIME", Self.clockText(store.reading.sampledAt), size: size)
            Spacer(minLength: 0)
            Image(systemName: deck.isAwake ? "sun.max.fill" : "moon.zzz")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(deck.isAwake ? Self.amber.opacity(0.8) : Color.secondary)
                .accessibilityLabel(deck.isAwake ? "屏幕常亮" : "自动息屏")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusItem(_ title: String, _ value: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: size * 0.78, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Self.secondary)
        }
        .lineLimit(1)
    }

    // MARK: - 数字

    /// 有值时定宽补位（1Hz 下不重排）；没值时不补位，交给调用方缩小字号。
    private struct DeckNumber {
        var text: String
        var isPlaceholder: Bool
    }

    private static func number(
        _ value: Double?,
        decimals: Int,
        width: Int = 5,
        signed: Bool = false
    ) -> DeckNumber {
        guard let value, value.isFinite else {
            return DeckNumber(text: "—", isPlaceholder: true)
        }
        return DeckNumber(
            text: SharedSensorSnapshot.valueText(value, decimals: decimals, width: width, signed: signed),
            isPlaceholder: false
        )
    }

    // MARK: - 样式

    private static let amber = Color(red: 1.0, green: 0.62, blue: 0.30)
    private static let primary = Color(red: 0.98, green: 0.86, blue: 0.72)
    private static let secondary = Color(red: 0.78, green: 0.68, blue: 0.56)

    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

#Preview("Landscape", traits: .landscapeLeft) {
    DeckView()
        .environment(ThermalStore.preview)
        .environment(DeckMode())
        .preferredColorScheme(.dark)
}
