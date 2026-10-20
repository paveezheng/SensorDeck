// App ↔ Widget 共享容器标识。快照只走 App Group 容器里的文件。
// 不用 UserDefaults suite：真机上 CFPrefs 会拒绝这个容器
// （"Using kCFPreferencesAnyUser with a container is only allowed for System Containers"），
// 那条兜底路径实际是死的，留着只是每秒白写一次 plist。

import Foundation

nonisolated enum AppGroup {
    static let identifier = "group.com.personal.sensordeck"
    static let widgetKind = "SensorDeckStandBy"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var snapshotFileURL: URL? {
        containerURL?.appendingPathComponent("snapshot.json")
    }
}
