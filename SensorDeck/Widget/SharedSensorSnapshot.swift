// App Group JSON 快照（snapshot.json）：App 写、Widget 只读。不要在这里碰 IOKit。
// 数字格式化也放这里：App 端用它算“显示值是否变了”，Widget 端用它渲染，两边必须一致。

import Foundation

struct SharedSensorSnapshot: Codable, Equatable, Sendable {
    var batteryCelsius: Double?
    var thermalState: String
    var updatedAt: Date
    var batteryLevel: Double?
    var isCharging: Bool
    var hidSensors: [HIDEntry]
    var cpuUsage: Double?
    var voltageVolts: Double?
    var currentAmps: Double?
    var powerWatts: Double?

    struct HIDEntry: Codable, Equatable, Sendable {
        var name: String
        var celsius: Double
    }

    /// 快照多久之后算过期（AGENTS.md 规定 30 分钟）。
    static let staleAfter: TimeInterval = 30 * 60

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(updatedAt) > Self.staleAfter
    }

    var isStale: Bool {
        isStale(at: Date())
    }

    var staleDate: Date {
        updatedAt.addingTimeInterval(Self.staleAfter)
    }

    // MARK: - 显示格式

    /// 数字宽度固定（用 U+2007 figure space 左补），配合 monospacedDigit 让布局不抖。
    static func valueText(_ value: Double?, decimals: Int, width: Int = 5, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return pad("—", to: width) }
        let format = signed ? "%+.\(decimals)f" : "%.\(decimals)f"
        return pad(String(format: format, value), to: width)
    }

    static func pad(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return String(repeating: "\u{2007}", count: width - text.count) + text
    }

    var voltageText: String { Self.valueText(voltageVolts, decimals: 2) }
    var currentText: String { Self.valueText(currentAmps, decimals: 2, signed: true) }
    var powerText: String { Self.valueText(powerWatts, decimals: 1) }

    var thermalTitle: String {
        guard let first = thermalState.first else { return "—" }
        return first.uppercased() + thermalState.dropFirst()
    }

    /// Widget 上真正会被看到的内容。App 端拿它判断“要不要叫醒 WidgetKit”。
    var displayKey: String {
        [voltageText, currentText, powerText, thermalState].joined(separator: "|")
    }

    // MARK: - App Group I/O

    static func loadFromAppGroup() -> SharedSensorSnapshot? {
        guard let url = AppGroup.snapshotFileURL, let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try makeDecoder().decode(SharedSensorSnapshot.self, from: data)
        } catch {
            NSLog("[SensorDeck] snapshot decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 只写 App Group 容器里的文件。1 秒一次的原子写没问题。
    func saveToAppGroup() {
        guard let url = AppGroup.snapshotFileURL else {
            return
        }
        do {
            try Self.makeEncoder().encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("[SensorDeck] snapshot write failed: \(error.localizedDescription)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
