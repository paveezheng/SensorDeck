// App Group JSON 快照：App 写、Widget 只读。不要在这里碰 IOKit。

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

    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 30 * 60
    }

    static func loadFromAppGroup() -> SharedSensorSnapshot? {
        if let url = AppGroup.snapshotFileURL, let data = try? Data(contentsOf: url) {
            if let snapshot = try? makeDecoder().decode(SharedSensorSnapshot.self, from: data) {
                return snapshot
            }
        }
        guard let data = AppGroup.userDefaults?.data(forKey: AppGroup.snapshotKey) else {
            return nil
        }
        do {
            return try makeDecoder().decode(SharedSensorSnapshot.self, from: data)
        } catch {
            NSLog("[SensorDeck] snapshot decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveToAppGroup() {
        do {
            let data = try Self.makeEncoder().encode(self)
            if let url = AppGroup.snapshotFileURL {
                try data.write(to: url, options: .atomic)
            }
            AppGroup.userDefaults?.set(data, forKey: AppGroup.snapshotKey)
        } catch {
            NSLog("[SensorDeck] snapshot encode failed: \(error.localizedDescription)")
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
