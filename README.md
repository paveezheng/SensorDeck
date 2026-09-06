# SensorDeck

个人用 iPhone 仪表盘：前台读温度 / 热状态，StandBy 小组件只显示 App 写好的快照。

不要用正式版 Xcode 26 打开。本工程按 **Xcode 27 beta + iOS 27** 配置。

## 文件职责

| 路径 | 职责 |
| --- | --- |
| `App/SensorDeckApp.swift` | SwiftUI 入口，前台启动采样 |
| `App/DashboardView.swift` | 单页仪表盘 |
| `App/SensorRow.swift` | 列表里的一行 |
| `Domain/SensorReading.swift` | 读数模型 |
| `Domain/ThermalStore.swift` | 每秒采样并写入 App Group |
| `Native/ThermalReader.*` | 唯一允许碰 IOKit / IOHID / Mach 的地方 |
| `Shared/AppGroup.swift` | `group.com.personal.sensordeck` |
| `Widget/SharedSensorSnapshot.swift` | JSON 快照编解码 |
| `Widget/SensorDeckWidget.swift` | StandBy 小组件 UI |
| `Widget/SensorDeckWidgetBundle.swift` | Widget 入口 |

## 第一次跑到 iPhone 上（按这个做）

模拟器没有这些传感器。真机才能看到电池温度和 HID 列表。

### 0. 你需要什么

- Mac 上的 **Xcode-beta**（27）
- 一根充电线
- 免费 Apple ID（手机下 App 用的那个就行，不必付费开发者账号）
- iPhone 系统尽量是 **iOS 27**。如果还是 iOS 26，见文末「Deployment Target」

### 1. iPhone：打开开发者模式

1. iPhone **设置 → 隐私与安全性 → 开发者模式**
2. 打开，手机会重启
3. 重启后再确认一次「打开」

没有这一项：先用线连上 Mac，用 Xcode-beta 打开本工程一次，再回头看设置。

### 2. 用线连上，信任这台电脑

1. 线连 iPhone 和 Mac
2. iPhone 弹出「要信任这台电脑吗？」→ **信任**，输入锁屏密码
3. Mac 上如果弹出「要访问 iPhone 吗？」→ 允许

### 3. 用 Xcode-beta 打开工程

不要点正式版 Xcode。

- 访达里打开 `SensorDeck.xcodeproj`
- 或终端：

```bash
open -a Xcode-beta "/Volumes/Default/Documents/CodeProjects/sensor-deck/SensorDeck.xcodeproj"
```

第一次打开 Xcode-beta 会装额外组件，等它装完。

### 4. 登录 Apple ID（Personal Team）

1. Xcode 菜单 **Xcode → Settings… → Accounts**
2. 左下角 **+** → **Apple ID**
3. 登录你的 Apple ID
4. 登录成功后，右边会出现 **Personal Team**（个人团队）。这就是免费签名，不用填 Team ID

### 5. 两个 Target 都选同一个 Team

左侧点蓝色 **SensorDeck** 工程图标。

**SensorDeck** target → **Signing & Capabilities**

- Team：选你的名字（Personal Team）
- Bundle Identifier：`com.personal.sensordeck`
- 勾选 Automatically manage signing
- 应能看到 App Group：`group.com.personal.sensordeck`

再点 **SensorDeckWidget** target，做完全一样的事：

- Team 必须和 App **同一个**
- Bundle Identifier：`com.personal.sensordeck.widget`

如果提示 Bundle ID 被占用，把两个 ID 都改成带你名字的，例如：

- `com.personal.sensordeck.yan`
- `com.personal.sensordeck.yan.widget`

App Group 名字两边保持 `group.com.personal.sensordeck` 即可。

### 6. 顶部运行目标选你的 iPhone

窗口最上方，Scheme 选 **SensorDeck**，右边设备列表选 **你的 iPhone 名字**。

不要选 `iPhone 17` 这种模拟器。

### 7. 点 Run（⌘R）

第一次通常会停在 iPhone 上的信任提示：

1. iPhone **设置 → 通用 → VPN 与设备管理**（有的系统叫「设备管理」）
2. 点你的 Apple ID → **信任**
3. 回 Xcode 再点一次 Run

装成功后主屏幕会出现 SensorDeck。点开应看到热状态和电量；温度可能是数字，也可能是 `—` / Restricted，取决于这台机的沙盒是否允许私有 API。

免费账号装上去的 App **大约 7 天过期**。过期后回 Xcode 再 Run 一次即可。

### 8. 把小组件放到 StandBy

1. 先在真机打开一次 SensorDeck（让它写出快照）
2. iPhone **充电 + 横放 + 锁屏**，进入 StandBy
3. 长按卡片 → 选 SensorDeck（小尺寸）

小组件自己不读温度，只显示 App 写下的最后一次快照。超过 30 分钟会标 `STALE`。

## 为什么 Widget 不能自己读温度

Widget 是系统拉起的小扩展进程，不是 App。

- 不能链接 / 调用 IOKit、IOHID、dlsym 私有符号（工程里 Widget target 也没有链这些）
- 系统对扩展的刷新次数和沙盒更严，私有传感器 API 在扩展里更容易直接失败
- 私有 API 字符串也不应出现在 Widget 二进制里

做法：App 在前台每 1 秒采样，把 JSON 写入 `group.com.personal.sensordeck`，然后 `WidgetCenter.reloadTimelines`。Widget 只读这份 JSON，读不到就显示 `—`，不会崩。

## 怎么看私有 API 有没有成功

1. 真机 Run，保持 App 开着
2. Xcode 底部打开 **Console**（View → Debug Area → Activate Console）
3. 过滤 `[SensorDeck]`

| 日志 | 含义 |
| --- | --- |
| `battery °C=31.8 (raw=3180, raw / 100 (centi-°C)) via AppleSmartBattery.Temperature` | 电池温度成功。3180 表示百分之一摄氏度，界面显示 31.8°C |
| `HID thermal: 12 sensors (matching 0xff00/5)` | HID 热传感器列表成功 |
| `HID symbols missing` / `IOHIDEventSystemClientCreate returned nil` | 私有 HID 被拦，界面 HID 行为 Restricted |
| `AppleSmartBattery service missing` 且 `IOPS Temperature missing` | 电池温度 Restricted / Unavailable，热状态和电量仍应显示 |
| `simulator: native IOKit/HID skipped` | 你在模拟器上跑，这是预期 |

公开 API（`ProcessInfo.thermalState`、`UIDevice` 电量）不走 IOKit，失败也不该白屏。

## 工程关键设置

- Bundle ID：`com.personal.sensordeck` / `com.personal.sensordeck.widget`
- App Group：`group.com.personal.sensordeck`（两个 target 的 entitlements）
- Bridging Header：`SensorDeck/Native/SensorDeck-Bridging-Header.h`（仅 App）
- App 弱链 IOKit：`OTHER_LDFLAGS = -weak_framework IOKit`，Optional
- Widget **不**链 IOKit，也 **不**编译 `ThermalReader.m`
- Widget kind：`SensorDeckStandBy`
- 签名：Automatic + Personal Team，不写死 Team ID

## 如果 iPhone 还不是 iOS 27

Xcode 会报无法安装。在两个 target 的 **General → Minimum Deployments** 改成你手机的版本（这些 API 从 iOS 18 就能编过）。App 和 Widget 要改成同一个数字。

## Preview

- App：`DashboardView.swift` 底部 `#Preview` 用固定示例数据
- Widget：`SensorDeckWidget.swift` 底部 `#Preview` 显示 `BAT 32.1°`
- 模拟器真运行（不是 Preview）走 Unavailable，这是故意的
