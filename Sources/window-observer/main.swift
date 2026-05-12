import Foundation

Task { @MainActor in
    WindowObserverApp.shared.start()
}

RunLoop.main.run()
