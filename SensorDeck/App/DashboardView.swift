// 单页仪表盘：电池温度、热状态、电量、HID 列表。

import SwiftUI

struct DashboardView: View {
    @Environment(ThermalStore.self) private var store
    @Environment(DeckMode.self) private var deck

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                batteryBlock
                sensorList
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                // 没读到值时 "—" 在 72pt 下是一条大横杠，缩掉一半才像占位符。
                let hasTemperature = store.reading.batteryCelsius != nil
                Text(store.reading.batteryTemperatureText)
                    .font(.system(size: hasTemperature ? 72 : 34, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        hasTemperature
                            ? Color(red: 1.0, green: 0.62, blue: 0.30)
                            : Color.secondary
                    )
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText())

                Text(store.reading.batteryCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            awakeToggle
        }
    }

    /// 竖屏常亮开关。横屏会自动常亮，跟这个开关无关。
    private var awakeToggle: some View {
        Button {
            deck.keepAwakeInPortrait.toggle()
        } label: {
            Label(
                deck.keepAwakeInPortrait ? "常亮" : "自动息屏",
                systemImage: deck.keepAwakeInPortrait ? "sun.max.fill" : "moon.zzz"
            )
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(
                deck.keepAwakeInPortrait
                    ? Color(red: 1.0, green: 0.62, blue: 0.30)
                    : Color.secondary
            )
            .background(Color.white.opacity(deck.keepAwakeInPortrait ? 0.12 : 0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.reading.thermal.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(store.reading.thermal.color)
                .background(store.reading.thermal.color.opacity(0.16))
                .clipShape(Capsule())

            HStack(spacing: 16) {
                labeledValue("Battery", store.reading.batteryPercentText)
                labeledValue("State", store.reading.charging.title)
            }

            HStack(spacing: 16) {
                labeledValue("Voltage", store.reading.voltageText)
                labeledValue("Current", store.reading.currentText)
                labeledValue("Power", store.reading.powerText)
            }

            Text(store.reading.electricalCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var sensorList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HID thermal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            if store.reading.hidSensors.isEmpty {
                SensorRow(
                    title: "HID thermal sensors",
                    value: store.reading.hidAvailability.label
                )
            } else {
                ForEach(store.reading.hidSensors) { sensor in
                    SensorRow(title: sensor.name, value: sensor.valueText)
                    if sensor.id != store.reading.hidSensors.last?.id {
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }

            Divider().overlay(Color.white.opacity(0.08))
            SensorRow(
                title: "CPU",
                value: store.reading.cpuPercentText,
                footnote: "占用率，不是温度"
            )
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Updated \(timeText(store.reading.sampledAt))")
            Text("Sample interval 1s")
            Text("横屏进入 Deck 常亮模式")
            Text("Personal use only")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

#Preview {
    DashboardView()
        .environment(ThermalStore.preview)
        .environment(DeckMode())
        .preferredColorScheme(.dark)
}
