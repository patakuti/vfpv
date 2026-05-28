# vfpv — Android

Drone FPV flight controlled by tilting your device.

## Requirements

- Android 10+ (API 30+)
- Accelerometer (required for tilt control)
- arm64-v8a or x86_64 device / emulator

## Build & Install

### Prerequisites

- Godot Engine 4.4+ with Android export templates installed
- Android SDK (build-tools 34+, platform-tools)
- Debug keystore configured in Godot export settings

### Build APK

```bash
godot --headless --export-debug "Android" vfpv.apk
```

### Install & Launch (ADB)

```bash
adb install -r vfpv.apk
adb shell monkey -p com.patakuti.vfpv -c android.intent.category.LAUNCHER 1
```

For an emulator:

```bash
adb -s emulator-5554 install -r vfpv.apk
adb -s emulator-5554 shell monkey -p com.patakuti.vfpv -c android.intent.category.LAUNCHER 1
```

## Controls

| Input | Action |
|---|---|
| Tilt forward | Increase speed |
| Tilt back | Decrease speed |
| Tilt left / right | Yaw left / right |
| Swipe up on right half of screen | Ascend |
| Swipe down on right half of screen | Descend |
| Pause button (top-left) | Open pause menu |

Speed range and tilt sensitivity can be adjusted in the Settings screen.

## Pause Menu

Tap the **| |** button in the top-left corner to pause.

| Button | Action |
|---|---|
| Resume | Unpause and continue flying |
| Settings | Open settings screen |
| Quit | Exit the app |

## Settings Screen

Accessible from the pause menu.

| Setting | Description |
|---|---|
| Calibrate Tilt | Set current device orientation as neutral (flat = min speed, tilt forward = max speed) |
| Min Speed | Minimum flight speed in m/s (10–150) |
| Max Speed | Maximum flight speed in m/s (50–300) |
| Stage | Select terrain type: Terrain / City / Canyon |
| Quality | Rendering quality: Low / Mid / High / Auto |
| God Mode | Bounce off terrain instead of crashing |
| Camera | FPV (first-person) or Follow camera |

Settings are saved to `user://settings.cfg` and restored on next launch.

## Notes

- **Tilt calibration** — Tap "Calibrate Tilt" while holding the device in your preferred neutral position (typically near-flat). The current accelerometer reading is saved as the zero reference.
- **Emulator** — The emulator does not have a real accelerometer. Use the debug keys (↑↓←→ / W / S) to simulate tilt and altitude in debug builds.
- **BGM / SFX** — Same as desktop; BGM auto-starts, boost and crash sounds are generated at runtime.
