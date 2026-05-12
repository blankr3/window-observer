import Foundation

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

func renderAsciiLayout(
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

func debugPrintEvent(
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
