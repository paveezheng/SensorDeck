// 仪表盘一行：传感器名称 + 温度/状态。

import SwiftUI

struct SensorRow: View {
    let title: String
    let value: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Text(value)
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    List {
        SensorRow(title: "TS0", value: "34.2°C")
        SensorRow(title: "CPU", value: "18%", footnote: "占用率，不是温度")
    }
    .preferredColorScheme(.dark)
}
