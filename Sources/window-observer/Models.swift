import Foundation

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
