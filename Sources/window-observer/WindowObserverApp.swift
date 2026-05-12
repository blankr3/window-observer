import Foundation
import AppKit
import Dispatch

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
    private var sigintSource: DispatchSourceSignal?
    private var shouldExit = false

    private var foregroundWindowID: Int?
    private var minimizedWindows: Set<Int> = []
    private var lastTitleEmitAt: [Int: Date] = [:]
    private var pendingTitleRecord: [Int: WindowRecord] = [:]
    private let titleDebounceInterval: TimeInterval = 0.12

    private lazy var eventsLogURL: URL = {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = cwd.appendingPathComponent(eventsLogFileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }()

    private init() {}

    func start() {
        setupSignalHandling()
        emitSnapshot()
        refreshMinimizedStateFromAX()
        registerCurrentApps()
        observeWorkspace()
        startPolling()
        updateForegroundFromActiveApp()
        emitNote("observer_started")
    }

    func stop() {
        guard !shouldExit else { return }
        shouldExit = true

        pollTimer?.cancel()
        pollTimer = nil

        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()

        sigintSource?.cancel()
        sigintSource = nil

        let pids = Set(knownWindows.values.map { $0.pid })
        for pid in pids {
            axManager.unregister(pid: pid)
        }

        emitNote("observer_stopped")
        exit(0)
    }

    func handleAX(notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification,
             kAXApplicationActivatedNotification:
            updateForegroundFromActiveApp()

        case "AXWindowMiniaturized", "AXWindowDeminiaturized":
            refreshMinimizedStateFromAX()

        default:
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
    }

    private func setupSignalHandling() {
        signal(SIGINT, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.stop()
        }
        source.resume()
        sigintSource = source
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
                self.refreshMinimizedStateFromAX()
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
                self.refreshMinimizedStateFromAX()
                self.emitNote("app_terminated pid=\(app.processIdentifier)")
            }
        }

        let activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.updateForegroundFromActiveApp()
            }
        }

        workspaceObservers = [launchObserver, terminateObserver, activateObserver]
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollOnce()
        }
        pollTimer = timer
        timer.resume()
    }

    private func pollOnce() {
        let current = listInScopeWindows()
        let currentMap = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })

        var debugEntries: [(String, WindowRecord)] = []
        let now = Date()

        for (windowID, record) in currentMap {
            if let previous = knownWindows[windowID] {
                if previous.bounds != record.bounds {
                    let resized = previous.bounds.width != record.bounds.width || previous.bounds.height != record.bounds.height
                    debugEntries.append((resized ? "resized" : "moved", record))
                }

                if previous.title != record.title {
                    pendingTitleRecord[windowID] = record
                }

                if previous.isOnScreen != record.isOnScreen {
                    debugEntries.append((record.isOnScreen ? "shown" : "hidden", record))
                }
            } else {
                debugEntries.append(("window_created", record))
                axManager.register(pid: record.pid)
            }
        }

        for (windowID, pendingRecord) in pendingTitleRecord {
            if let last = lastTitleEmitAt[windowID],
               now.timeIntervalSince(last) < titleDebounceInterval {
                continue
            }
            if currentMap[windowID] != nil {
                debugEntries.append(("title_changed", pendingRecord))
                lastTitleEmitAt[windowID] = now
            }
            pendingTitleRecord[windowID] = nil
        }

        let oldMinimized = minimizedWindows
        refreshMinimizedStateFromAX()

        for windowID in minimizedWindows.subtracting(oldMinimized) {
            if let record = knownWindows[windowID] ?? currentMap[windowID] {
                debugEntries.append(("minimized", record))
            }
        }

        for windowID in oldMinimized.subtracting(minimizedWindows) {
            if let record = knownWindows[windowID] ?? currentMap[windowID] {
                debugEntries.append(("restored", record))
            }
        }

        for (windowID, oldRecord) in knownWindows where currentMap[windowID] == nil {
            // If the window is currently known to be minimized (via AX), don't treat its absence
            // from the CGWindowList as a destruction — it may be off-screen due to minimization.
            if minimizedWindows.contains(windowID) {
                continue
            }

            debugEntries.append(("window_destroyed", oldRecord))
            pendingTitleRecord[windowID] = nil
            lastTitleEmitAt[windowID] = nil
            if foregroundWindowID == windowID {
                foregroundWindowID = nil
            }
        }

        knownWindows = currentMap
        updateForegroundFromActiveApp()

        for (type, record) in debugEntries {
            emitWindowEvent(type: type, record: record)
        }
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

    private func appendJSONToEventsFile(_ data: Data) {
        let url = eventsLogURL
        DispatchQueue.global(qos: .utility).async {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            } catch {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func emit(_ payload: EventPayload) {
        if outputMode.contains(.json) {
            if let data = try? encoder.encode(payload) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
                appendJSONToEventsFile(data)
            }
        }

        if outputMode.contains(.debugAscii) {
            switch payload.eventType {
            case "snapshot":
                debugPrintEvent(
                    type: "snapshot",
                    record: nil,
                    windows: payload.windows,
                    foregroundWindowID: foregroundWindowID,
                    minimizedIDs: minimizedWindows
                )

            case "window_created", "window_destroyed", "moved", "resized",
                 "title_changed", "shown", "hidden",
                 "foreground_changed", "minimized", "restored":
                let windows = Array(knownWindows.values)
                let fallbackRecord = WindowRecord(
                    windowID: payload.windowID ?? -1,
                    pid: payload.pid ?? 0,
                    ownerName: payload.ownerName ?? "?",
                    executableName: payload.executableName,
                    bundleIdentifier: payload.bundleIdentifier,
                    title: payload.title,
                    layer: 0,
                    isOnScreen: true,
                    bounds: payload.bounds ?? WindowBounds(x: 0, y: 0, width: 0, height: 0)
                )
                let record = payload.windowID.flatMap { knownWindows[$0] } ?? fallbackRecord
                debugPrintEvent(
                    type: payload.eventType,
                    record: record,
                    windows: windows,
                    foregroundWindowID: foregroundWindowID,
                    minimizedIDs: minimizedWindows
                )

            default:
                break
            }
        }
    }

    private func updateForegroundFromActiveApp() {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            app.activationPolicy == .regular
        else { return }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )

        guard result == .success, let focusedValue else { return }

        let focusedElement = focusedValue as! AXUIElement
        let axSnapshot = makeAXWindowSnapshot(pid: pid, windowElement: focusedElement)

        guard let matchedWindowID = matchAXWindowToCGWindow(axSnapshot) else { return }
        handleForegroundCandidate(windowID: matchedWindowID)
    }

    private func handleForegroundCandidate(windowID: Int) {
        guard let record = knownWindows[windowID] else { return }
        guard windowID != foregroundWindowID else { return }

        foregroundWindowID = windowID

        let payload = EventPayload(
            timestamp: isoFormatter.string(from: Date()),
            eventType: "foreground_changed",
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

    private func refreshMinimizedStateFromAX() {
        var newMinimized: Set<Int> = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = copyAXWindows(appElement: appElement) else { continue }

            for windowElement in windows {
                let snapshot = makeAXWindowSnapshot(pid: app.processIdentifier, windowElement: windowElement)
                guard snapshot.isMinimized else { continue }
                if let matchedWindowID = matchAXWindowToCGWindow(snapshot, allowKnownWindowsFallback: true) {
                    newMinimized.insert(matchedWindowID)
                }
            }
        }

        minimizedWindows = newMinimized
    }

    private func copyAXWindows(appElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? [AXUIElement]
    }

    private func makeAXWindowSnapshot(pid: pid_t, windowElement: AXUIElement) -> AXWindowSnapshot {
        let title = copyAXString(element: windowElement, attribute: kAXTitleAttribute)
        let bounds = copyAXBounds(element: windowElement)
        let isMinimized = copyAXBool(element: windowElement, attribute: kAXMinimizedAttribute) ?? false
        return AXWindowSnapshot(pid: pid, title: title, bounds: bounds, isMinimized: isMinimized)
    }

    private func matchAXWindowToCGWindow(_ axWindow: AXWindowSnapshot, allowKnownWindowsFallback: Bool = false) -> Int? {
        let candidates = knownWindows.values.filter { $0.pid == axWindow.pid }

        if candidates.isEmpty { return nil }

        let normalizedAXTitle = normalizeTitle(axWindow.title)
        let titleMatches = candidates.filter { normalizeTitle($0.title) == normalizedAXTitle }
        let pool = !titleMatches.isEmpty ? titleMatches : Array(candidates)

        if let axBounds = axWindow.bounds {
            let best = pool.min { lhs, rhs in
                distance(lhs.bounds, axBounds) < distance(rhs.bounds, axBounds)
            }
            if let best, distance(best.bounds, axBounds) <= 80 {
                return best.windowID
            }
        }

        if allowKnownWindowsFallback, pool.count == 1 {
            return pool[0].windowID
        }

        return nil
    }
}
