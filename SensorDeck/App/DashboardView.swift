// 单页仪表盘：电池温度、热状态、电量、HID 列表。

import SwiftUI

struct DashboardView: View {
    @Environment(ThermalStore.self) private var store

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
        VStack(alignment: .leading, spacing: 8) {
            Text(store.reading.batteryTemperatureText)
                .font(.system(size: 72, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.30))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())

            Text(store.reading.batteryCaption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .preferredColorScheme(.dark)
}
