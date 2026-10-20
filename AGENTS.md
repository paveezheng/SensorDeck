# SensorDeck — agent notes

Personal iOS 27 SwiftUI app. Not an App Store product. Do not add account, iCloud, analytics, ads, Health, location, charts history, settings pages, or third-party SPM.

`CLAUDE.md` is a symlink to this file.

## What it is

Two surfaces today (a Live Activity is permitted but not built):

1. **App** — one dark surface with two layouts, picked by canvas orientation:
   - Portrait **dashboard**: battery °C, `ProcessInfo.thermalState`, charge %, HID thermal list, CPU usage (labeled as occupancy, not temperature), charging voltage / current / power.
   - Landscape **Deck**: big glanceable readout, screen kept awake (`isIdleTimerDisabled`). This is the only way to get a real 1 Hz display — see "Going faster than the widget".
2. **StandBy widget** (`kind`: `SensorDeckStandBy`) — small card. Voltage, current, power, thermal state. Read-only.

Simulator has no these sensors. Runtime must show Unavailable / `—`, not crash. `#Preview` may use fixed sample data (`ThermalStore.preview`).

## Stack

- Xcode 27 beta, iOS 27+, Swift 6, SwiftUI lifecycle only (no UIKit `AppDelegate`)
- State: `@Observable` (`ThermalStore`). No Combine-as-architecture, no TCA, no SwiftData, no Firebase
- Targets: `SensorDeck` (`com.personal.sensordeck`) + `SensorDeckWidget` (`com.personal.sensordeck.widget`)
- App Group: `group.com.personal.sensordeck`
- Open with **Xcode-beta**, not Xcode 26

## Layout

```
SensorDeck/
  App/        SensorDeckApp, RootView, DashboardView, DeckView, DeckMode, SensorRow
  Domain/     SensorReading, ThermalStore
  Native/     ThermalReader.h/.m, bridging header  ← App only
  Shared/     AppGroup
  Widget/     widget UI, SharedSensorSnapshot, widget Info/entitlements
```

| File | Role |
| --- | --- |
| `Native/ThermalReader.*` | Only place that may touch IOKit / IOHID / `dlsym` / Mach `host_processor_info` |
| `Domain/ThermalStore.swift` | 1s sample, App Group write, widget reload, charging-background sample |
| `Widget/SharedSensorSnapshot.swift` | Codable snapshot; App writes, widget reads |
| `Shared/AppGroup.swift` | App Group id, `snapshot.json` URL, widget kind |
| `App/RootView.swift` | canvas-orientation switch: wide → `DeckView`, else `DashboardView` |
| `App/DeckMode.swift` | `isIdleTimerDisabled`, face-down detection, OLED burn-in offset |

## Hard rules

- UI must not call IOKit / IOHID.
- Widget must not link IOKit, must not `dlsym` private symbols, must not contain private API strings, must not use timers or network.
- Widget compiles only: `AppGroup.swift`, `SharedSensorSnapshot.swift`, `SensorDeckWidget.swift`, `SensorDeckWidgetBundle.swift`.
- Bridging header (`SensorDeck/Native/SensorDeck-Bridging-Header.h`) is App-only.
- App weakly links IOKit (`-weak_framework IOKit`, Optional).
- Fail closed: private API miss → still show public thermal state + battery %; temp/V/I/W become Restricted / Unavailable / `—`. No `fatalError`.
- Temperature UI: one decimal °C. Do not invent 0.01 precision. Do not label HID names as “CPU Die”.
- CPU row is usage, not temperature.
- StandBy card must not animate between timeline entries: `.transaction { $0.animation = nil }` on the root, `.contentTransition(.identity)` on each value. Numbers change in place.
- StandBy value strings are fixed-width (U+2007 padded, `monospacedDigit`) so the layout never reflows. Format them once in `SharedSensorSnapshot`, never in the view.
- In Deck's wide layout the two columns get **fixed width fractions**, never `Spacer()`. Letting them negotiate means the right column narrows when a value falls back to `—`, the hero gets more room, and `minimumScaleFactor` visibly re-grows the temperature.
- Deck hides the status bar and `persistentSystemOverlays` (home indicator) — a fixed white bar for hours on an always-on OLED is exactly the burn-in shape to avoid. The Dynamic Island is hardware plus a system layer: there is no app-facing API for it (SwiftUI has none), so do not accept tasks premised on hiding it.
- Deck values use the same fixed-width formatting, but **not** for the missing-value case: a padded `—` renders as a giant bar at hero font sizes. Shrink the placeholder and drop the padding (`DeckView.number`).
- Portrait/landscape comes from the **canvas size** (`RootView`'s `GeometryReader`), never from `UIDevice.orientation`. The device orientation ignores rotation lock — it reports landscape while the UI is still portrait (the iOS Simulator does this at launch too), and laying out Deck on a portrait canvas is the bug that produces. `UIDevice.orientation` is used for exactly one thing: face-down → drop keep-awake.
- Supported orientations live in **build settings**, not `SensorDeck/Info.plist`: the project has `GENERATE_INFOPLIST_FILE = YES`, so `INFOPLIST_KEY_UISupportedInterfaceOrientations` (Debug *and* Release) is what actually ships. It was portrait-only, which silently made Deck mode unreachable. Check the built product, not the source plist: `plutil -p <built>.app/Info.plist | grep -A4 Orientations`.
- The Xcode project uses a file-system synchronized group: **every new file under `App/`, `Domain/`, `Native/` must be added to the `SensorDeckWidget` target's `membershipExceptions`** in `project.pbxproj`, or it silently lands in the widget and breaks the four-file rule. Verify with `nm -a <appex binary> | grep <TypeName>` → 0 hits.

## How sensors are read (App process)

Public (always implement):

- `ProcessInfo.thermalState` (Nominal / Fair / Serious / Critical)
- `UIDevice` battery level + charging (`isBatteryMonitoringEnabled = true`)

Private, best-effort, `dlsym`:

- Battery °C: `AppleSmartBattery` `Temperature` (often centi-°C: `3180` → `31.8°C`), then IOPS, then HID **`gas gauge battery`** (this device’s fuel-gauge name). Not `PMU tcal`, not `Charger TQ*`.
- HID thermal list: `IOHIDEventSystemClient`, `kIOHIDEventTypeTemperature` (15), matching `0xff00/5`.
- Charging electricals on this phone (iPhone 17 Pro Max style names, not old `vbat`/`vbus`):
  - Voltage: `Charger VQ0u` (USB/PD rail), pack fallback `PMU VP0u`
  - Current: `Charger IQ0u`
  - **Rails.** `V`/`I`/`W` are dimension prefixes; the `Q<n>` / `P<n>` that follows identifies the rail. Measured on this phone: `Q0` is the battery side (`VQ0l`≈4.0 V, `IQ0B`≈0.4–1.0 A; `VQ0u` and `IQ0u` sit at 0), `Q1` is the input side (`VQ1u`≈9.8 V, no current sensor), `P0` is the pack (`PMU VP0u`). Use `SDRailID`.
  - Power is `V × I` **only when both come from the same rail** (`voltagePairsWithCurrent`). Pick the current first, then find its rail's voltage. Never let a missing sensor silently fall back across rails: `VQ1u` drops out of individual HID samples, and the old code swapped to `PMU VP0u`, so voltage flapped 9.8 ↔ 4.1 V and power alternated between input power and a cross-rail product of nothing.
  - **`Charger WQ0u` is not watts.** Measured: rises ~1.5/s and wraps to ~0 at ~14 — a sawtooth counter, in both wired and wireless sessions. Diagnostics only; never display it as power. Adapter rating is `IOPSCopyExternalPowerAdapterDetails` Watts — label as rated, not live (it reports 5 W while the phone draws ~9 W).
  - The HID sensor list is not stable across sessions or within one (27 vs 28 sensors; `IQ0B` present with one charger and not another; wireless charging exposes no `VQ1u`/`IQ0u` input rail at all). Never hardcode a sensor name; always score and fall back.
- Current sensor picking (`SDPickChargerCurrent`): the name bonus (`iq0u` / `charger` / `ibat`) is only awarded to rows reading **>= 0.02 A**. Both naive versions are wrong:
  - Hard-skipping rows under 0.02 A makes current *and* power vanish together during trickle charge (`power = V × I`) — that reading is real, not noise.
  - Awarding the name bonus unconditionally lets a dead rail win. On this phone **`Charger IQ0u` reads 0 permanently and the live rail is `Charger IQ0B`**; +20 for `iq0u` pins current at 0.00 A forever.
  - Withholding the bonus does both jobs: the live rail wins on magnitude alone even at 0.005 A, and a dead rail can never outrank it.
- Unplugged (`batteryState == .unplugged`, checked in `ThermalStore.sample`, not in the native reader) blanks current/power to `—`. Voltage stays: it comes from the pack (`PMU VP0u`) and is real either way.
- `AppleSmartBattery` on current iOS may only publish `BatteryInstalled` / `ExternalConnected`. HID is the real path.

## App Group

App (foreground 1s, background 2s; if charging, try to keep sampling after lock):

1. Write JSON to App Group `snapshot.json` every sample. **File only** — no UserDefaults suite: CFPrefs rejects this container on device ("Using kCFPreferencesAnyUser with a container is only allowed for System Containers"), so that fallback never worked and only cost a plist write per sample.
2. `WidgetCenter.shared.reloadTimelines(ofKind: "SensorDeckStandBy")` — see budget rules below

Widget: read `snapshot.json`. Missing data → `—` / STALE if snapshot older than 30 minutes.

### Widget reload budget

WidgetKit reloads are rationed. Burning them is what makes StandBy stop updating after a few minutes, so:

- Reload only when `SharedSensorSnapshot.displayKey` changes — the exact strings the card renders. Same numbers → no reload.
- Floors: 10s foreground, 15s background, 300s when nothing changed or `getCurrentConfigurations` says the kind isn't installed. `force: true` only for scene changes and BG-task teardown.
- Timeline policy is adaptive: `.after(+60s)` when the snapshot is <2 min old (app is alive), else `.after(+300s)`. Do not ask for 30s — the system won't honor it.
- Emit an extra entry at `snapshot.staleDate` so STALE lights up without a reload.
- Every BG task must call `setTaskCompleted(success:)` exactly once. Not completing lowers the app's scheduling score and kills the background path after a few rounds.
- Submit requests with `submitTaskRequest(_:)` off the main thread and log failures. `submit(_:)` is deprecated in iOS 27 and `try?` hides `.unavailable` (Background App Refresh off).

## Going faster than the widget

Live Activity is **allowed** (this used to be excluded; it no longer is). Not built yet — if you build one, it's a third surface, not a replacement for the StandBy widget.

The real constraint isn't which surface renders, it's whether the app process is alive to produce numbers:

- `Activity.update(_:)` is a local call — no server, no push needed — but it only works while the app is running. Suspended app → frozen Live Activity, same as a frozen widget.
- Live Activities render on the Lock Screen, in the Dynamic Island, and (verify on device) in StandBy. StandBy's widget view and its Live Activity view are separate screens.
- `BGContinuedProcessingTaskRequest` (iOS 26+) is the only public way to keep sampling for a long stretch after lock. Its system UI *is* a Live Activity (`BGContinuedProcessingTask.updateTitle:subtitle:` says so). Constraints, from the SDK header:
  - Must be submitted while the app is foregrounded — it cannot self-renew after it ends
  - Identifier must be wildcard form `com.personal.sensordeck.<context>.*`, and the wildcard goes in `BGTaskSchedulerPermittedIdentifiers`
  - Must report `NSProgress`; "tasks that appear stalled may be forcibly expired". An open-ended monitor has no natural progress — drive it against a fixed session length
  - User-cancellable; queued requests die when the app is swiped out of the app switcher
- `beginBackgroundTask` is ~30s. Do not plan around it lasting longer.
- Baseline that always works, and what's actually shipped: **Deck mode** — app in the foreground, landscape, `isIdleTimerDisabled = true`. Full 1 Hz, no background tricks, no budget. Keep-awake is `isActive && !isFaceDown && (isLandscape || keepAwakeInPortrait)`; the portrait override is the pill in the dashboard header. Never leave the idle timer disabled on `.background`.

## Do not

- Ship / privacy nutrition / tracking
- Login, iCloud, HealthKit, Core Location
- Extra design-system files
- Third-party packages
- Put private API work in the widget target

## Verify

True numbers: physical iPhone + Xcode-beta. Console filter `[SensorDeck]`.

Expect logs like:

- `battery °C=38.3 via HID 'gas gauge battery'`
- `P=V*I on rail Q0;` or `P skipped: V(...) and I(...) on different rails;` — says whether the pair was coherent
- `HID voltage: Charger VQ0u=... PMU VP0u=...`
- `HID current: Charger IQ0u=...`
- `adapter Watts=45; V=14.80 (Charger VQ0u); I=1.209 A; P=17.89 W`

Simulator: `simulator: native IOKit/HID skipped`.
