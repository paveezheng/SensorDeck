// App ↔ Widget 共享容器标识。两端都只通过这里拿 UserDefaults suite。

import Foundation

enum AppGroup {
    static let identifier = "group.com.personal.sensordeck"
    static let snapshotKey = "sensorSnapshotJSON"
    static let widgetKind = "SensorDeckStandBy"

    static var userDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var snapshotFileURL: URL? {
        containerURL?.appendingPathComponent("snapshot.json")
    }
}
