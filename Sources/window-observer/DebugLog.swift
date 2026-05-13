import Foundation
import Dispatch

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

    /// Flush any pending writes. Blocks until the internal queue has drained.
    func flush() {
        queue.sync {}
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
