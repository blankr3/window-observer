import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

struct WindowBounds: Codable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct WindowRecord: Codable, Equatable {
    let windowID: Int
    let pid: Int32
    let ownerName: String
    let executableName: String?
    let bundleIdentifier: String?
    let title: String?
    let layer: Int
    let isOnScreen: Bool
    let bounds: WindowBounds
}

struct EventPayload: Codable {
    let timestamp: String
    let eventType: String
    let windowID: Int?
    let pid: Int32?
    let ownerName: String?
    let executableName: String?
    let bundleIdentifier: String?
    let title: String?
    let bounds: WindowBounds?
    let windows: [WindowRecord]?
    let note: String?
}

@MainActor
final class AXObserverManager {
    private var observers: [pid_t: AXObserver] = [:]
    private var runLoopSources: [pid_t: CFRunLoopSource] = [:]

    func register(pid: pid_t) {
        guard observers[pid] == nil else { return }
        guard pid != getpid() else { return }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let app = Unmanaged<WindowObserverApp>.fromOpaque(refcon).takeUnretainedValue()

            Task { @MainActor in
                app.handleAX(notification: notification as String, element: element)
            }
        }

        let result = AXObserverCreate(pid, callback, &observer)
        guard result == .success, let observer else { return }

        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(WindowObserverApp.shared).toOpaque())

        let appNotifications = [
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXMainWindowChangedNotification,
            kAXApplicationActivatedNotification,
            kAXApplicationDeactivatedNotification
        ]

        for name in appNotifications {
            _ = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        if let windows = copyAXWindows(appElement: appElement) {
            for window in windows {
                _ = AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, refcon)
                _ = AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
                _ = AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
                _ = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
            }
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        observers[pid] = observer
        runLoopSources[pid] = source
    }

    func unregister(pid: pid_t) {
        if let source = runLoopSources.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        observers.removeValue(forKey: pid)
    }

    private func copyAXWindows(appElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? [AXUIElement]
    }
}

@MainActor
final class WindowObserverApp {
    static let shared = WindowObserverApp()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let isoFormatter = ISO8601DateFormatter()
    private let axManager = AXObserverManager()
    private var knownWindows: [Int: WindowRecord] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shouldExit = false

    private init() {}

    func start() {
        emitSnapshot()
        registerCurrentApps()
        observeWorkspace()
        startPolling()
        emitNote("observer_started")
    }

    func stop() {
        guard !shouldExit else { return }
        shouldExit = true

        pollTimer?.cancel()
        pollTimer = nil

        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()

        let pids = Set(knownWindows.values.map { $0.pid })
        for pid in pids {
            axManager.unregister(pid: pid)
        }

        emitNote("observer_stopped")
        exit(0)
    }

    func handleAX(notification: String, element: AXUIElement) {
        let title = copyAXString(element: element, attribute: kAXTitleAttribute)

        let payload = EventPayload(
            timestamp: isoFormatter.string(from: Date()),
            eventType: "ax_notification",
            windowID: nil,
            pid: nil,
            ownerName: nil,
            executableName: nil,
            bundleIdentifier: nil,
            title: title,
            bounds: nil,
            windows: nil,
            note: notification
        )

        emit(payload)
    }

    private func registerCurrentApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            axManager.register(pid: app.processIdentifier)
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.activationPolicy == .regular else { return }

            MainActor.assumeIsolated {
                self.axManager.register(pid: app.processIdentifier)
                self.emitNote("app_launched pid=\(app.processIdentifier)")
            }
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            MainActor.assumeIsolated {
                self.axManager.unregister(pid: app.processIdentifier)
                self.emitNote("app_terminated pid=\(app.processIdentifier)")
            }
        }

        workspaceObservers = [launchObserver, terminateObserver]
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.pollOnce()
            }
        }
        pollTimer = timer
        timer.resume()
    }

    private func pollOnce() {
        let current = listInScopeWindows()
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        for (windowID, record) in currentMap {
            if let previous = knownWindows[windowID] {
                if previous.bounds != record.bounds {
                    let resized = previous.bounds.width != record.bounds.width || previous.bounds.height != record.bounds.height
                    emitWindowEvent(type: resized ? "resized" : "moved", record: record)
                }

                if previous.title != record.title {
                    emitWindowEvent(type: "title_changed", record: record)
                }

                if previous.isOnScreen != record.isOnScreen {
                    emitWindowEvent(type: record.isOnScreen ? "shown" : "hidden", record: record)
                }
            } else {
                emitWindowEvent(type: "window_created", record: record)
                axManager.register(pid: record.pid)
            }
        }

        for (windowID, oldRecord) in knownWindows where currentMap[windowID] == nil {
            emitWindowEvent(type: "window_destroyed", record: oldRecord)
        }

        knownWindows = currentMap
    }

    private func emitSnapshot() {
        let windows = listInScopeWindows()
        knownWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })

        let payload = EventPayload(
            timestamp: isoFormatter.string(from: Date()),
            eventType: "snapshot",
            windowID: nil,
            pid: nil,
            ownerName: nil,
            executableName: nil,
            bundleIdentifier: nil,
            title: nil,
            bounds: nil,
            windows: windows,
            note: nil
        )

        emit(payload)
    }

    private func emitWindowEvent(type: String, record: WindowRecord) {
        let payload = EventPayload(
            timestamp: isoFormatter.string(from: Date()),
            eventType: type,
            windowID: record.windowID,
            pid: record.pid,
            ownerName: record.ownerName,
            executableName: record.executableName,
            bundleIdentifier: record.bundleIdentifier,
            title: record.title,
            bounds: record.bounds,
            windows: nil,
            note: nil
        )

        emit(payload)
    }

    private func emitNote(_ note: String) {
        let payload = EventPayload(
            timestamp: isoFormatter.string(from: Date()),
            eventType: "note",
            windowID: nil,
            pid: nil,
            ownerName: nil,
            executableName: nil,
            bundleIdentifier: nil,
            title: nil,
            bounds: nil,
            windows: nil,
            note: note
        )

        emit(payload)
    }

    private func emit(_ payload: EventPayload) {
        guard let data = try? encoder.encode(payload) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

func executableName(for pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.executableURL?.lastPathComponent
}

func bundleIdentifier(for pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

func parseBounds(_ raw: Any?) -> WindowBounds? {
    guard
        let dict = raw as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: dict)
    else {
        return nil
    }

    return WindowBounds(
        x: Int(rect.origin.x),
        y: Int(rect.origin.y),
        width: Int(rect.size.width),
        height: Int(rect.size.height)
    )
}

func copyAXString(element: AXUIElement, attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value as? String
}

func isInScope(_ window: [String: Any]) -> Bool {
    let ownerName = (window[kCGWindowOwnerName as String] as? String) ?? ""
    let layer = (window[kCGWindowLayer as String] as? Int) ?? -1
    let title = (window[kCGWindowName as String] as? String) ?? ""
    let isOnScreen = (window[kCGWindowIsOnscreen as String] as? Int) ?? 0

    guard let bounds = parseBounds(window[kCGWindowBounds as String]) else {
        return false
    }

    let excludedOwners: Set<String> = [
        "Dock",
        "Window Server",
        "Control Center",
        "Notification Center"
    ]

    if excludedOwners.contains(ownerName) { return false }
    if layer != 0 { return false }
    if isOnScreen == 0 { return false }
    if bounds.width < 120 || bounds.height < 80 { return false }
    if ownerName.isEmpty { return false }

    if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
    }

    return true
}

func listInScopeWindows() -> [WindowRecord] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

    guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return infoList.compactMap { window in
        guard isInScope(window) else { return nil }

        guard
            let windowID = window[kCGWindowNumber as String] as? Int,
            let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
            let ownerName = window[kCGWindowOwnerName as String] as? String,
            let layer = window[kCGWindowLayer as String] as? Int,
            let bounds = parseBounds(window[kCGWindowBounds as String])
        else {
            return nil
        }

        let title = window[kCGWindowName as String] as? String
        let isOnScreen = ((window[kCGWindowIsOnscreen as String] as? Int) ?? 0) != 0

        return WindowRecord(
            windowID: windowID,
            pid: ownerPID,
            ownerName: ownerName,
            executableName: executableName(for: ownerPID),
            bundleIdentifier: bundleIdentifier(for: ownerPID),
            title: title?.isEmpty == true ? nil : title,
            layer: layer,
            isOnScreen: isOnScreen,
            bounds: bounds
        )
    }
}

signal(SIGINT) { _ in
    Task { @MainActor in
        WindowObserverApp.shared.stop()
    }
}

Task { @MainActor in
    WindowObserverApp.shared.start()
}

RunLoop.main.run()