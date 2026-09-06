// 前台 1 秒采样；充电进入后台/StandBy 时继续写 App Group 并刷新 Widget。

import BackgroundTasks
import Foundation
import SwiftUI
import UIKit
import WidgetKit

@Observable
@MainActor
final class ThermalStore {
    enum Mode {
        case live
        case preview
    }

    static let shared = ThermalStore()
    static let refreshTaskID = "com.personal.sensordeck.refresh"
    static let processTaskID = "com.personal.sensordeck.process"

    private(set) var reading: SensorReading
    private let mode: Mode
    private var samplingTask: Task<Void, Never>?
    private var thermalTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var lastWidgetReload = Date.distantPast

    init(mode: Mode = .live) {
        self.mode = mode
        self.reading = mode == .preview ? .previewSample : .empty
    }

    static var preview: ThermalStore {
        ThermalStore(mode: .preview)
    }

    static func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            handleAppRefresh(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processTaskID, using: nil) { task in
            handleProcessing(task)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard mode == .live else { return }
        switch phase {
        case .active:
            endBackgroundTask()
            start()
            scheduleBackgroundTasks()
        case .background:
            startBackgroundIfNeeded()
        default:
            break
        }
    }

    func start() {
        guard mode == .live else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        sample(reloadWidget: true)

        if samplingTask == nil {
            samplingTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    self.sample(reloadWidget: true)
                }
            }
        }

        if thermalTask == nil {
            thermalTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: ProcessInfo.thermalStateDidChangeNotification
                )
                for await _ in notifications {
                    if Task.isCancelled { break }
                    self?.sample(reloadWidget: true)
                }
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        thermalTask?.cancel()
        thermalTask = nil
    }

    private func startBackgroundIfNeeded() {
        scheduleBackgroundTasks()
        guard isChargingNow() else {
            stop()
            return
        }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SensorDeck.sample") { [weak self] in
                Task { @MainActor in
                    self?.endBackgroundTask()
                    self?.stop()
                    self?.scheduleBackgroundTasks()
                }
            }
        }
        start()
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func isChargingNow() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return true
        default:
            return false
        }
    }

    func sample(reloadWidget: Bool) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let level = device.batteryLevel
        let batteryLevel: Double? = level < 0 ? nil : Double(level)
        let charging: ChargingState = {
            switch device.batteryState {
            case .charging: return .charging
            case .unplugged: return .unplugged
            case .full: return .full
            default: return .unknown
            }
        }()
        let thermal = ThermalLevel(processInfo: ProcessInfo.processInfo.thermalState)
        let native = ThermalReader.readOnce()

        let next = SensorReading(
            batteryCelsius: native.batteryCelsius?.doubleValue,
            batteryTemperatureAvailability: Self.availability(native.batteryTemperatureStatus),
            batteryTemperatureSource: native.batteryTemperatureSource,
            thermal: thermal,
            batteryLevel: batteryLevel,
            charging: charging,
            voltageVolts: native.voltageVolts?.doubleValue,
            voltageSource: native.voltageSource,
            voltageAvailability: Self.availability(native.voltageStatus),
            currentAmps: native.currentAmps?.doubleValue,
            currentSource: native.currentSource,
            currentAvailability: Self.availability(native.currentStatus),
            powerWatts: native.powerWatts?.doubleValue,
            adapterWatts: native.adapterWatts?.doubleValue,
            hidSensors: native.hidSensors.enumerated().map { index, sensor in
                NamedTemperature(index: index, name: sensor.name, celsius: sensor.celsius)
            },
            hidAvailability: Self.availability(native.hidStatus),
            cpuUsage: native.cpuUsage?.doubleValue,
            cpuAvailability: Self.availability(native.cpuStatus),
            sampledAt: Date(),
            nativeLog: native.diagnosticLine
        )
        reading = next
        persist(next)
        if reloadWidget {
            reloadWidgetsThrottled(force: false)
        }
    }

    private func reloadWidgetsThrottled(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWidgetReload) >= 5 else { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }

    private func persist(_ reading: SensorReading) {
        let snapshot = SharedSensorSnapshot(
            batteryCelsius: reading.batteryCelsius,
            thermalState: reading.thermal.rawValue,
            updatedAt: reading.sampledAt,
            batteryLevel: reading.batteryLevel,
            isCharging: reading.charging == .charging || reading.charging == .full,
            hidSensors: reading.hidSensors.map {
                SharedSensorSnapshot.HIDEntry(name: $0.name, celsius: $0.celsius)
            },
            cpuUsage: reading.cpuUsage,
            voltageVolts: reading.voltageVolts,
            currentAmps: reading.currentAmps,
            powerWatts: reading.powerWatts
        )
        snapshot.saveToAppGroup()
    }

    func scheduleBackgroundTasks() {
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let process = BGProcessingTaskRequest(identifier: Self.processTaskID)
        process.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        process.requiresExternalPower = true
        process.requiresNetworkConnectivity = false
        try? BGTaskScheduler.shared.submit(process)
    }

    private static func handleAppRefresh(_ task: BGTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        Task { @MainActor in
            shared.sample(reloadWidget: true)
            shared.reloadWidgetsThrottled(force: true)
            shared.scheduleBackgroundTasks()
            task.setTaskCompleted(success: true)
        }
    }

    private static func handleProcessing(_ task: BGTask) {
        Task { @MainActor in
            shared.start()
            shared.scheduleBackgroundTasks()
        }
        task.expirationHandler = {
            Task { @MainActor in
                shared.stop()
                shared.scheduleBackgroundTasks()
                task.setTaskCompleted(success: true)
            }
        }
    }

    private static func availability(_ status: SDNativeStatus) -> ReadingAvailability {
        switch status {
        case .available: return .available
        case .restricted: return .restricted
        default: return .unavailable
        }
    }
}
