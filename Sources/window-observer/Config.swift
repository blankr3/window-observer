import Foundation

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
