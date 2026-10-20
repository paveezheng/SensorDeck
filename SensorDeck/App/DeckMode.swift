// Deck 常亮模式：横屏自动切大字读数并禁用息屏，拿到真正的 1Hz。
//
// 两个信号各司其职，不要混用：
// - 是否横屏 → 由 RootView 的画布尺寸给（updateCanvas）。这是唯一可信的依据：
//   UIDevice.orientation 报的是"设备物理朝向"，跟系统旋转锁定无关，
//   锁了竖屏（以及模拟器里）它照样报 landscape，照它排版会得到竖屏画布上的横屏布局。
// - 是否扣在桌上 → 由 UIDevice.orientationDidChangeNotification（加速度计）给。
//   画布尺寸看不见这个，而屏幕朝下时没有任何理由继续点亮 OLED。
//
// 加速度计走 UIDevice 通知而不是 CoreMotion：不需要权限、不需要 Info.plist 声明、
// 不需要自己开采样循环。

import SwiftUI
import UIKit

@Observable
@MainActor
final class DeckMode {
    static let shared = DeckMode()

    /// 竖屏也强制常亮。横屏本身就常亮，不受这个开关影响。
    var keepAwakeInPortrait: Bool {
        didSet {
            guard oldValue != keepAwakeInPortrait else { return }
            UserDefaults.standard.set(keepAwakeInPortrait, forKey: Self.keepAwakeKey)
            applyIdleTimer()
        }
    }

    /// 界面（画布）是否横屏 —— Deck 布局与常亮的依据。
    private(set) var isLandscape = false
    /// 屏幕是否朝下扣着。扣着就不常亮。
    private(set) var isFaceDown = false
    private(set) var isAwake = false
    /// OLED 常亮防烧屏：每分钟整体挪几个点。不常亮时归零。
    private(set) var burnInOffset = CGSize.zero

    private static let keepAwakeKey = "deck.keepAwakeInPortrait"
    private static let burnInStep: CGFloat = 4
    private static let burnInInterval: Duration = .seconds(60)

    private var isActive = true
    private var orientationTask: Task<Void, Never>?
    private var burnInTask: Task<Void, Never>?
    private var burnInIndex = 0

    init() {
        keepAwakeInPortrait = UserDefaults.standard.bool(forKey: Self.keepAwakeKey)
    }

    /// RootView 在画布尺寸变化时调用。
    func updateCanvas(isWide: Bool) {
        guard isWide != isLandscape else { return }
        isLandscape = isWide
        NSLog("[SensorDeck] canvas → \(isWide ? "landscape" : "portrait")")
        applyIdleTimer()
    }

    func start() {
        let device = UIDevice.current
        device.beginGeneratingDeviceOrientationNotifications()
        updateOrientation(device.orientation)

        if orientationTask == nil {
            orientationTask = Task { [weak self] in
                let notifications = NotificationCenter.default.notifications(
                    named: UIDevice.orientationDidChangeNotification
                )
                for await _ in notifications {
                    if Task.isCancelled { break }
                    self?.updateOrientation(UIDevice.current.orientation)
                }
            }
        }

        if burnInTask == nil {
            burnInTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.burnInInterval)
                    if Task.isCancelled { break }
                    self?.advanceBurnInOffset()
                }
            }
        }

        applyIdleTimer()
    }

    func stop() {
        orientationTask?.cancel()
        orientationTask = nil
        burnInTask?.cancel()
        burnInTask = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            start()
        case .background:
            // 后台绝不能留着 isIdleTimerDisabled。
            isActive = false
            applyIdleTimer()
            stop()
        default:
            break
        }
    }

    /// 只用来判断"扣在桌上"。横竖屏一律不看这里 —— 见文件头注释。
    private func updateOrientation(_ orientation: UIDeviceOrientation) {
        let faceDown = orientation == .faceDown
        guard faceDown != isFaceDown else { return }
        isFaceDown = faceDown
        NSLog("[SensorDeck] device face down=\(faceDown)")
        applyIdleTimer()
    }

    private func applyIdleTimer() {
        let awake = isActive && !isFaceDown && (isLandscape || keepAwakeInPortrait)
        guard awake != isAwake else { return }
        isAwake = awake
        UIApplication.shared.isIdleTimerDisabled = awake
        NSLog("[SensorDeck] idle timer disabled=\(awake)")
        if !awake {
            burnInIndex = 0
            burnInOffset = .zero
        }
    }

    private func advanceBurnInOffset() {
        guard isAwake else { return }
        burnInIndex = (burnInIndex + 1) % 4
        let step = Self.burnInStep
        switch burnInIndex {
        case 1: burnInOffset = CGSize(width: step, height: -step)
        case 2: burnInOffset = CGSize(width: 0, height: step)
        case 3: burnInOffset = CGSize(width: -step, height: 0)
        default: burnInOffset = .zero
        }
    }
}
