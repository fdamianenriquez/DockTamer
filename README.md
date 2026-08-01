# DockTamer
 
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/-Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)
 
DockTamer is a sleek and lightweight macOS utility that modifies the native Dock's behavior to provide **"Click-to-Minimize"** functionality, reminiscent of the behavior found in Windows and GNOME desktop environments.

## Features

- **Click-to-Minimize:** Intercepts clicks on the macOS Dock. If an application is already active, clicking its icon in the Dock will intelligently minimize it.
- **Smart Restoration:** If an application is activated and all of its windows are currently minimized, DockTamer will automatically un-minimize and restore them for you.
- **Menu Bar App:** Runs completely in the background without cluttering your Dock. It features a custom-designed, dynamically generated menu bar icon that natively blends in with macOS.
- **Easy Toggle:** Quickly enable or disable the Click-to-Minimize functionality directly from the menu bar drop-down.
- **Seamless Permission Handling:** Automatically requests the necessary Accessibility permissions and detects when they are granted in real-time, removing the need to restart the app.

## Requirements

- **OS:** macOS 13.0 (Ventura) or later.
- **Permissions:** Due to the nature of intercepting system-wide mouse events, DockTamer requires **Accessibility** permissions (Privacy & Security -> Accessibility).

## How it Works

DockTamer leverages two major macOS components to perform its duties efficiently without draining battery or resources:
1. **CGEventTap:** To silently monitor and intercept mouse clicks specifically aimed at the Dock's screen area.
2. **Accessibility API (AXUIElement):** To query the state of applications and manipulate window attributes (such as the `kAXMinimizedAttribute`) to minimize or restore them.
3. **NSWorkspace Notifications:** To detect when an application is brought to the foreground (`didActivateApplicationNotification`), triggering the smart window restoration.

## Project Structure & Architecture

The application is built entirely in Swift and uses modern macOS APIs:
- `AppDelegate.swift`: Manages the application lifecycle, sets up the dynamic Menu Bar icon, and handles Accessibility permission logic.
- `AppActivationMonitor.swift`: Observes `NSWorkspace` to restore an app's windows if they are all minimized upon activation.
- `DockClickMonitor` (Assumed): Handles the `CGEventTap` to intercept Dock clicks.
- Built using **XcodeGen** (`project.yml`) for clean project generation and management.

## Installation / Setup

If you want to build the project from source:

1. Clone the repository.
2. Ensure you have [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed.
3. Run `xcodegen` in the repository root to generate the `DockTamer.xcodeproj`.
4. Open the generated project in Xcode and build/run.

Alternatively, you can run the pre-packaged application found in `DockTamer.dmg`.

## License & Privacy

DockTamer processes all events locally on your machine. It does not phone home, track your clicks outside of the Dock, or log your application usage. 
