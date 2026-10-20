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
    nonisolated static let refreshTaskID = "com.personal.sensordeck.refresh"
    nonisolated static let processTaskID = "com.personal.sensordeck.process"

    // WidgetKit 的重载是有配额的：显示值没变就别叫醒它，否则几轮之后系统直接不给刷了。
    private static let foregroundReloadFloor: TimeInterval = 10
    private static let backgroundReloadFloor: TimeInterval = 15
    private static let idleReloadFloor: TimeInterval = 300
    private static let widgetProbeInterval: TimeInterval = 60
    private static let foregroundSampleInterval: Duration = .seconds(1)
    private static let backgroundSampleInterval: Duration = .seconds(2)
    // beginBackgroundTask 只给约 30 秒；BGProcessingTask 也别跑满，留出收尾时间。
    private static let processingTaskBudget: TimeInterval = 25

    private(set) var reading: SensorReading
    private let mode: Mode
    private var samplingTask: Task<Void, Never>?
    private var thermalTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var isForeground = true
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetKey: String?
    private var lastWidgetProbe = Date.distantPast
    private var widgetInstalled: Bool?

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
            isForeground = true
            endBackgroundTask()
            start()
            scheduleBackgroundTasks()
        case .background:
            isForeground = false
            startBackgroundIfNeeded()
        default:
            break
        }
    }

    func start() {
        guard mode == .live else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        probeWidgetInstallation(force: true)
        sample(reloadWidget: true)

        if samplingTask == nil {
            samplingTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    let interval = self.isForeground
                        ? Self.foregroundSampleInterval
                        : Self.backgroundSampleInterval
                    try? await Task.sleep(for: interval)
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
                    // 热状态是 Widget 上会变色的那一行，值一变就立刻推。
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
            // 最后再推一次，别让 StandBy 停在半旧的数字上。
            reloadWidgets(force: true)
            stop()
            return
        }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SensorDeck.sample") { [weak self] in
                Task { @MainActor in
                    NSLog("[SensorDeck] background assertion expired; suspending sampler")
                    self?.sample(reloadWidget: false)
                    self?.reloadWidgets(force: true)
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

        // 拔线时充电电流轨没有意义，显示 — 而不是 +0.00 A / 0.0 W。
        // 电压保留：它来自电池组（PMU VP0u），拔线后依然是真实读数。
        // 只在明确 unplugged 时抑制；.unknown 不动，免得读不到电池状态就误杀。
        let unplugged = charging == .unplugged
        let currentAmps: Double? = unplugged ? nil : native.currentAmps?.doubleValue
        let powerWatts: Double? = unplugged ? nil : native.powerWatts?.doubleValue
        let currentAvailability: ReadingAvailability = unplugged
            ? .unavailable
            : Self.availability(native.currentStatus)

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
            currentAmps: currentAmps,
            currentSource: unplugged ? nil : native.currentSource,
            currentAvailability: currentAvailability,
            powerWatts: powerWatts,
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

        let snapshot = Self.makeSnapshot(next)
        persist(snapshot)
        probeWidgetInstallation(force: false)
        if reloadWidget {
            reloadWidgets(force: false, key: snapshot.displayKey)
        }
    }

    // MARK: - Widget 刷新

    /// `force` 用于场景切换 / 后台任务收尾；平时只有 Widget 上真会变的字符串变了才推。
    private func reloadWidgets(force: Bool, key: String? = nil) {
        let now = Date()
        if !force {
            let changed = key.map { $0 != lastWidgetKey } ?? false
            let floor: TimeInterval
            if changed && widgetInstalled != false {
                floor = isForeground ? Self.foregroundReloadFloor : Self.backgroundReloadFloor
            } else {
                // 值没变，或者系统说这个 kind 没被装出去：退到最低频，别硬刷。
                floor = Self.idleReloadFloor
            }
            guard now.timeIntervalSince(lastWidgetReload) >= floor else { return }
        }
        if let key {
            lastWidgetKey = key
        }
        lastWidgetReload = now
        WidgetCenter.shared.reloadTimelines(ofKind: AppGroup.widgetKind)
    }

    /// 没装 Widget 还一直 reload 纯属浪费配额；装上之后最多 60 秒被发现。
    private func probeWidgetInstallation(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWidgetProbe) >= Self.widgetProbeInterval else { return }
        lastWidgetProbe = now
        Task { @MainActor [weak self] in
            let installed = await Self.widgetIsInstalled()
            guard let self else { return }
            if self.widgetInstalled != installed {
                let state = installed.map { $0 ? "yes" : "no" } ?? "unknown"
                NSLog("[SensorDeck] StandBy widget installed=\(state)")
            }
            self.widgetInstalled = installed
        }
    }

    private nonisolated static func widgetIsInstalled() async -> Bool? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let infos):
                    continuation.resume(returning: infos.contains { $0.kind == AppGroup.widgetKind })
                case .failure(let error):
                    NSLog("[SensorDeck] widget configuration probe failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - App Group

    private static func makeSnapshot(_ reading: SensorReading) -> SharedSensorSnapshot {
        SharedSensorSnapshot(
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
    }

    private func persist(_ snapshot: SharedSensorSnapshot) {
        snapshot.saveToAppGroup()
    }

    // MARK: - 后台任务

    func scheduleBackgroundTasks() {
        // iOS 27 的提交接口明确要求别在主线程调用。
        Task.detached(priority: .utility) {
            await Self.submitTaskRequests()
        }
    }

    private nonisolated static func submitTaskRequests() async {
        await submit {
            let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
            // 系统实际给的间隔远大于这个值，写实一点，别硬要 60 秒。
            request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            return request
        }
        await submit {
            let request = BGProcessingTaskRequest(identifier: processTaskID)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
            request.requiresExternalPower = true
            request.requiresNetworkConnectivity = false
            return request
        }
    }

    private nonisolated static func submit(_ makeRequest: @Sendable () -> BGTaskRequest) async {
        let request = makeRequest()
        do {
            // 旧的 submit(_:) 在 iOS 27 已废弃，且吞掉了一部分错误。
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } catch {
            NSLog("[SensorDeck] BG submit failed (\(request.identifier)): \(error.localizedDescription)")
        }
    }

    private static func handleAppRefresh(_ task: BGTask) {
        let work = Task { @MainActor in
            shared.sample(reloadWidget: false)
            shared.reloadWidgets(force: true)
            await submitTaskRequests()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    private static func handleProcessing(_ task: BGTask) {
        let work = Task { @MainActor in
            await shared.runBoundedSampling(for: processingTaskBudget)
            shared.reloadWidgets(force: true)
            await submitTaskRequests()
            // 不 setTaskCompleted 会被系统记账，之后越来越难拿到后台机会。
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
        }
    }

    /// 后台任务里的有限时长采样：到点就退出，绝不留常驻循环。
    private func runBoundedSampling(for seconds: TimeInterval) async {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !Task.isCancelled, Date() < deadline {
            sample(reloadWidget: true)
            try? await Task.sleep(for: Self.backgroundSampleInterval)
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
