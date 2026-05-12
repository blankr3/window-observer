import Foundation
import ApplicationServices

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
