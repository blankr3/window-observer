import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Dispatch

// MARK: - Config

struct OutputMode: OptionSet {
    let rawValue: Int
    static let json       = OutputMode(rawValue: 1 << 0)
    static let debugAscii = OutputMode(rawValue: 1 << 1)
}

let outputMode: OutputMode = [.json, .debugAscii]

let asciiCols = 80
let asciiRows = 24
let debugLogFileName = "window-observer-debug.txt"
let eventsLogFileName = "window-observer-events.jsonl"

// MARK: - Models

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

struct AXWindowSnapshot {
    let pid: pid_t
    let title: String?
    let bounds: WindowBounds?
    let isMinimized: Bool
}

// MARK: - Debug Log

final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()

    private let url: URL
    private let queue = DispatchQueue(label: "window-observer.debug-log")

    private init() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.url = cwd.appendingPathComponent(debugLogFileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let header = """
        === window-observer debug log started \(ISO8601DateFormatter().string(from: Date())) ===

        """
        append(header)
    }

    func write(_ text: String) {
        Swift.print(text, terminator: "")
        append(text)
    }

    private func append(_ text: String) {
        queue.async { [url] in
            guard let data = text.data(using: .utf8) else { return }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - ASCII Rendering

private struct AsciiCell {
    var fill: Character = " "
    var up = false
    var down = false
    var left = false
    var right = false
}

private func asciiSymbolForOwner(_ name: String) -> Character {
    if name.lowercased().contains("code") { return "C" }
    if name.lowercased().contains("safari") { return "S" }
    if name.lowercased().contains("finder") { return "F" }
    if name.lowercased().contains("preview") { return "P" }
    if name.lowercased().contains("terminal") { return "T" }
    if let first = name.first { return Character(first.uppercased()) }
    return "?"
}

private func boxChar(up: Bool, down: Bool, left: Bool, right: Bool) -> Character {
    switch (up, down, left, right) {
    case (false, false, false, false): return " "
    case (false, false, true, true):   return "─"
    case (true, true, false, false):   return "│"
    case (false, true, false, true):   return "┌"
    case (false, true, true, false):   return "┐"
    case (true, false, false, true):   return "└"
    case (true, false, true, false):   return "┘"
    case (true, true, false, true):    return "├"
    case (true, true, true, false):    return "┤"
    case (false, true, true, true):    return "┬"
    case (true, false, true, true):    return "┴"
    case (true, true, true, true):     return "┼"
    default:
        if left || right { return "─" }
        if up || down { return "│" }
        return " "
    }
}

private func renderAsciiLayout(
    windows: [WindowRecord],
    foregroundWindowID: Int?,
    minimizedIDs: Set<Int>
) -> String {
    let visibleWindows = windows.filter { !minimizedIDs.contains($0.windowID) }

    var output: [String] = []

    if let foregroundWindowID,
       let fg = windows.first(where: { $0.windowID == foregroundWindowID }) {
        let title = (fg.title ?? "").isEmpty ? "-" : (fg.title ?? "-")
        output.append("Foreground: \(fg.ownerName)(\(fg.windowID)) \"\(title)\"")
    } else {
        output.append("Foreground: -")
    }

    if visibleWindows.isEmpty {
        output.append("(no visible windows in scope)")
    } else {
        let minX = visibleWindows.map { $0.bounds.x }.min() ?? 0
        let minY = visibleWindows.map { $0.bounds.y }.min() ?? 0
        let maxX = visibleWindows.map { $0.bounds.x + $0.bounds.width }.max() ?? (minX + 1)
        let maxY = visibleWindows.map { $0.bounds.y + $0.bounds.height }.max() ?? (minY + 1)

        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)

        let scaleX = Double(asciiCols - 1) / Double(spanX)
        let scaleY = Double(asciiRows - 1) / Double(spanY)

        var grid = Array(
            repeating: Array(repeating: AsciiCell(), count: asciiCols),
            count: asciiRows
        )

        func mapX(_ x: Int) -> Int {
            let fx = Double(x - minX) * scaleX
            return max(0, min(asciiCols - 1, Int(fx.rounded())))
        }

        func mapY(_ y: Int) -> Int {
            let fy = Double(y - minY) * scaleY
            return max(0, min(asciiRows - 1, Int(fy.rounded())))
        }

        for window in visibleWindows {
            let b = window.bounds
            let symbol = asciiSymbolForOwner(window.ownerName)

            let x0 = mapX(b.x)
            let y0 = mapY(b.y)
            let x1 = mapX(b.x + b.width)
            let y1 = mapY(b.y + b.height)

            let left = min(x0, x1)
            let right = max(x0, x1)
            let top = min(y0, y1)
            let bottom = max(y0, y1)

            if left >= right || top >= bottom { continue }

            for row in (top + 1)..<bottom {
                guard row >= 0 && row < asciiRows else { continue }
                for col in (left + 1)..<right {
                    guard col >= 0 && col < asciiCols else { continue }
                    grid[row][col].fill = symbol
                }
            }

            for col in left...right {
                guard col >= 0 && col < asciiCols else { continue }
                if top >= 0 && top < asciiRows { grid[top][col].down = true }
                if bottom >= 0 && bottom < asciiRows { grid[bottom][col].up = true }
            }

            for row in top...bottom {
                guard row >= 0 && row < asciiRows else { continue }
                if left >= 0 && left < asciiCols { grid[row][left].right = true }
                if right >= 0 && right < asciiCols { grid[row][right].left = true }
            }
        }

        for row in 0..<asciiRows {
            var line = ""
            for col in 0..<asciiCols {
                let cell = grid[row][col]
                let ch: Character
                if cell.up || cell.down || cell.left || cell.right {
                    ch = boxChar(up: cell.up, down: cell.down, left: cell.left, right: cell.right)
                } else {
                    ch = cell.fill
                }
                line.append(ch)
            }
            output.append(line)
        }
    }

    output.append("Legend:")
    for w in windows.sorted(by: { $0.windowID < $1.windowID }) {
        let sym = asciiSymbolForOwner(w.ownerName)
        let title = (w.title ?? "").isEmpty ? "-" : (w.title ?? "-")
        var tags: [String] = []
        if w.windowID == foregroundWindowID { tags.append("fg") }
        if minimizedIDs.contains(w.windowID) { tags.append("min") }
        let tagString = tags.isEmpty ? "" : " [\(tags.joined(separator: ","))]"
        output.append("  \(sym) = \(w.ownerName) (\(w.windowID)) \(w.bounds.x),\(w.bounds.y) \(w.bounds.width)x\(w.bounds.height) \"\(title)\"\(tagString)")
    }

    if !minimizedIDs.isEmpty {
        output.append("")
        output.append("Minimized:")
        for w in windows.filter({ minimizedIDs.contains($0.windowID) }).sorted(by: { $0.windowID < $1.windowID }) {
            let sym = asciiSymbolForOwner(w.ownerName)
            let title = (w.title ?? "").isEmpty ? "-" : (w.title ?? "-")
            output.append("  [\(sym)] \(w.ownerName)(\(w.windowID)) \"\(title)\"")
        }
    }

    return output.joined(separator: "\n") + "\n"
}

@MainActor
private func debugPrintEvent(
    type: String,
    record: WindowRecord?,
    windows: [WindowRecord]?,
    foregroundWindowID: Int?,
    minimizedIDs: Set<Int>
) {
    var out = ""

    switch type {
    case "snapshot":
        out += "[snapshot] \(windows?.count ?? 0) windows\n"
    case "foreground_changed":
        if let r = record {
            let title = (r.title ?? "").isEmpty ? "-" : (r.title ?? "-")
            out += "[foreground_changed] \(r.ownerName)(\(r.windowID)) \"\(title)\"\n"
        } else {
            out += "[foreground_changed]\n"
        }
    case "window_created", "window_destroyed", "moved", "resized",
         "title_changed", "shown", "hidden", "minimized", "restored":
        if let r = record {
            let title = (r.title ?? "").isEmpty ? "-" : (r.title ?? "-")
            out += "[\(type)] \(r.ownerName)(\(r.windowID)) \(r.bounds.x),\(r.bounds.y) \(r.bounds.width)x\(r.bounds.height) \"\(title)\"\n"
        } else {
            out += "[\(type)]\n"
        }
    default:
        return
    }

    if let windows {
        out += renderAsciiLayout(
            windows: windows,
            foregroundWindowID: foregroundWindowID,
            minimizedIDs: minimizedIDs
        )
        out += "\n"
    }

    DebugLog.shared.write(out)
}

// MARK: - AX Observer

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
                _ = AXObserverAddNotification(observer, window, "AXWindowMiniaturized" as CFString, refcon)
                _ = AXObserverAddNotification(observer, window, "AXWindowDeminiaturized" as CFString, refcon)
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

// MARK: - App

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

    private func normalizeTitle(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func distance(_ a: WindowBounds, _ b: WindowBounds) -> Int {
        let dx = abs(a.x - b.x)
        let dy = abs(a.y - b.y)
        let dw = abs(a.width - b.width)
        let dh = abs(a.height - b.height)
        return dx + dy + dw + dh
    }
}

// MARK: - Utility

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

func copyAXBool(element: AXUIElement, attribute: String) -> Bool? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }

    if let boolValue = value as? Bool {
        return boolValue
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    return nil
}

func copyAXBounds(element: AXUIElement) -> WindowBounds? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?

    let positionResult = AXUIElementCopyAttributeValue(
        element,
        kAXPositionAttribute as CFString,
        &positionValue
    )
    let sizeResult = AXUIElementCopyAttributeValue(
        element,
        kAXSizeAttribute as CFString,
        &sizeValue
    )

    guard
        positionResult == .success,
        sizeResult == .success,
        let positionValue,
        let sizeValue
    else {
        return nil
    }

    let positionAX = positionValue as! AXValue
    let sizeAX = sizeValue as! AXValue

    var point = CGPoint.zero
    var size = CGSize.zero

    guard
        AXValueGetType(positionAX) == .cgPoint,
        AXValueGetValue(positionAX, .cgPoint, &point),
        AXValueGetType(sizeAX) == .cgSize,
        AXValueGetValue(sizeAX, .cgSize, &size)
    else {
        return nil
    }

    return WindowBounds(
        x: Int(point.x),
        y: Int(point.y),
        width: Int(size.width),
        height: Int(size.height)
    )
}

func isInScope(_ window: [String: Any]) -> Bool {
    let ownerName = (window[kCGWindowOwnerName as String] as? String) ?? ""
    let layer = (window[kCGWindowLayer as String] as? Int) ?? -1
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

// MARK: - Entry

Task { @MainActor in
    WindowObserverApp.shared.start()
}

RunLoop.main.run()