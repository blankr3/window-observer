import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

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

func normalizeTitle(_ title: String?) -> String {
    (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func distance(_ a: WindowBounds, _ b: WindowBounds) -> Int {
    let dx = abs(a.x - b.x)
    let dy = abs(a.y - b.y)
    let dw = abs(a.width - b.width)
    let dh = abs(a.height - b.height)
    return dx + dy + dw + dh
}
