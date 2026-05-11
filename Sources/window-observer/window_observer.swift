import Foundation
import CoreGraphics
import AppKit

struct WindowBounds: Codable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct WindowInfo: Codable {
    let window_id: Int
    let pid: Int32
    let owner_name: String
    let executable_name: String?
    let title: String?
    let layer: Int
    let bounds: WindowBounds
}

struct SnapshotEvent: Codable {
    let timestamp: String
    let event_type: String
    let windows: [WindowInfo]
}

func executableName(for pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.executableURL?.lastPathComponent
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

func isInScope(_ window: [String: Any]) -> Bool {
    let ownerName = (window[kCGWindowOwnerName as String] as? String) ?? ""
    let layer = (window[kCGWindowLayer as String] as? Int) ?? -1
    let title = (window[kCGWindowName as String] as? String) ?? ""

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
    if bounds.width <= 0 || bounds.height <= 0 { return false }

    // v0 heuristic: keep windows that either have a title or belong to a visible app-like owner.
    if ownerName.isEmpty { return false }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        return true
    }

    return true
}

func listInScopeWindows() -> [WindowInfo] {
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

        return WindowInfo(
            window_id: windowID,
            pid: ownerPID,
            owner_name: ownerName,
            executable_name: executableName(for: ownerPID),
            title: title?.isEmpty == true ? nil : title,
            layer: layer,
            bounds: bounds
        )
    }
}

func emitSnapshot() throws {
    let event = SnapshotEvent(
        timestamp: ISO8601DateFormatter().string(from: Date()),
        event_type: "snapshot",
        windows: listInScopeWindows()
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let data = try encoder.encode(event)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

do {
    try emitSnapshot()
} catch {
    FileHandle.standardError.write("Failed to emit snapshot: \\(error)\\n".data(using: .utf8)!)
    exit(1)
}