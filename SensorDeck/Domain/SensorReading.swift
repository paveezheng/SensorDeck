// App 仪表盘的领域模型：公开热状态 / 电量 + 原生温度读数。

import SwiftUI

enum ReadingAvailability: String, Sendable {
    case available
    case unavailable
    case restricted

    var label: String {
        switch self {
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        case .restricted: return "Restricted"
        }
    }
}

enum ThermalLevel: String, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .nominal: return Color(red: 0.35, green: 0.82, blue: 0.48)
        case .fair: return Color(red: 0.95, green: 0.82, blue: 0.28)
        case .serious: return Color(red: 1.0, green: 0.55, blue: 0.22)
        case .critical: return Color(red: 1.0, green: 0.32, blue: 0.28)
        case .unknown: return Color.secondary
        }
    }

    init(processInfo: ProcessInfo.ThermalState) {
        switch processInfo {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

enum ChargingState: String, Sendable {
    case charging
    case unplugged
    case full
    case unknown

    var title: String {
        switch self {
        case .charging: return "Charging"
        case .unplugged: return "Unplugged"
        case .full: return "Full"
        case .unknown: return "Unknown"
        }
    }
}

struct NamedTemperature: Equatable, Identifiable, Sendable {
    var index: Int
    var name: String
    var celsius: Double

    var id: String { "\(index)-\(name)" }

    var valueText: String {
        String(format: "%.1f°C", celsius)
    }
}

struct SensorReading: Equatable, Sendable {
    var batteryCelsius: Double?
    var batteryTemperatureAvailability: ReadingAvailability
    var batteryTemperatureSource: String?
    var thermal: ThermalLevel
    var batteryLevel: Double?
    var charging: ChargingState
    var voltageVolts: Double?
    var voltageSource: String?
    var voltageAvailability: ReadingAvailability
    var currentAmps: Double?
    var currentSource: String?
    var currentAvailability: ReadingAvailability
    var powerWatts: Double?
    var adapterWatts: Double?
    var hidSensors: [NamedTemperature]
    var hidAvailability: ReadingAvailability
    var cpuUsage: Double?
    var cpuAvailability: ReadingAvailability
    var sampledAt: Date
    var nativeLog: String

    static let empty = SensorReading(
        batteryCelsius: nil,
        batteryTemperatureAvailability: .unavailable,
        batteryTemperatureSource: nil,
        thermal: .unknown,
        batteryLevel: nil,
        charging: .unknown,
        voltageVolts: nil,
        voltageSource: nil,
        voltageAvailability: .unavailable,
        currentAmps: nil,
        currentSource: nil,
        currentAvailability: .unavailable,
        powerWatts: nil,
        adapterWatts: nil,
        hidSensors: [],
        hidAvailability: .unavailable,
        cpuUsage: nil,
        cpuAvailability: .unavailable,
        sampledAt: Date(),
        nativeLog: ""
    )

    static let previewSample = SensorReading(
        batteryCelsius: 32.1,
        batteryTemperatureAvailability: .available,
        batteryTemperatureSource: "gas gauge battery",
        thermal: .fair,
        batteryLevel: 0.76,
        charging: .charging,
        voltageVolts: 4.18,
        voltageSource: "PMU vbat",
        voltageAvailability: .available,
        currentAmps: 0.35,
        currentSource: "PMU vbus",
        currentAvailability: .available,
        powerWatts: 1.5,
        adapterWatts: 20,
        hidSensors: [
            NamedTemperature(index: 0, name: "gas gauge battery", celsius: 32.1),
            NamedTemperature(index: 1, name: "PMU tdev1", celsius: 36.0),
            NamedTemperature(index: 2, name: "NAND CH0 temp", celsius: 34.2),
        ],
        hidAvailability: .available,
        cpuUsage: 0.18,
        cpuAvailability: .available,
        sampledAt: Date(),
        nativeLog: "preview sample"
    )

    var batteryTemperatureText: String {
        guard let batteryCelsius else { return "—" }
        return String(format: "%.1f°C", batteryCelsius)
    }

    var batteryPercentText: String {
        guard let batteryLevel else { return "—" }
        return "\(Int((batteryLevel * 100).rounded()))%"
    }

    var cpuPercentText: String {
        guard let cpuUsage else { return "—" }
        return "\(Int((cpuUsage * 100).rounded()))%"
    }

    var batteryCaption: String {
        switch batteryTemperatureAvailability {
        case .available:
            if let batteryTemperatureSource {
                let lowered = batteryTemperatureSource.lowercased()
                if lowered.contains("gas gauge") {
                    return "Battery · gas gauge"
                }
                return "Battery · \(batteryTemperatureSource)"
            }
            return "Battery"
        case .unavailable: return "Unavailable"
        case .restricted: return "Restricted"
        }
    }

    var voltageText: String {
        guard let voltageVolts else { return "—" }
        return String(format: "%.2f V", voltageVolts)
    }

    var currentText: String {
        guard let currentAmps else { return "—" }
        return String(format: "%+.2f A", currentAmps)
    }

    var powerText: String {
        guard let powerWatts else { return "—" }
        return String(format: "%.1f W", powerWatts)
    }

    var electricalCaption: String {
        let voltage = voltageSource ?? "—"
        let current = currentSource ?? "—"
        if voltageAvailability != .available && currentAvailability != .available {
            return "Voltage / current unavailable"
        }
        if let adapterWatts {
            return "\(voltage) × \(current) · adapter \(Int(adapterWatts.rounded())) W rated"
        }
        return "\(voltage) × \(current)"
    }
}
