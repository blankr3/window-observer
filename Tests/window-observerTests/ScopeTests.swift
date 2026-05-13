import XCTest
import CoreGraphics
@testable import window_observer

final class ScopeTests: XCTestCase {
    func boundsDict(_ rect: CGRect) -> NSDictionary {
        return ["X": rect.origin.x as NSNumber,
                "Y": rect.origin.y as NSNumber,
                "Width": rect.size.width as NSNumber,
                "Height": rect.size.height as NSNumber] as NSDictionary
    }

    func makeWindow(_ owner: String, layer: Int, onScreen: Int = 1, rect: CGRect = CGRect(x: 0, y: 0, width: 200, height: 200), title: String? = nil) -> [String: Any] {
        var d: [String: Any] = [:]
        d[kCGWindowOwnerName as String] = owner
        d[kCGWindowLayer as String] = layer
        d[kCGWindowIsOnscreen as String] = onScreen
        d[kCGWindowBounds as String] = boundsDict(rect)
        if let t = title { d[kCGWindowName as String] = t }
        return d
    }

    func testLayer0NormalWindowIsInScope() {
        let w = makeWindow("MyApp", layer: 0, title: "Document")
        XCTAssertTrue(isInScope(w))
    }

    func testSmallWindowExcluded() {
        let w = makeWindow("MyApp", layer: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 50), title: "Tiny")
        XCTAssertFalse(isInScope(w))
    }

    func testDockExcluded() {
        let w = makeWindow("Dock", layer: 0, title: "Dock")
        XCTAssertFalse(isInScope(w))
    }

    func testSpotlightWhitelisted() {
        let w = makeWindow("Spotlight", layer: 1, title: "Spotlight")
        XCTAssertTrue(isInScope(w))
    }

    func testSavePanelWhitelistedByTitle() {
        let w = makeWindow("TextEdit", layer: 2, title: "Save As")
        XCTAssertTrue(isInScope(w))
    }

    func testUtilityPanelShortTitle() {
        let w = makeWindow("MyApp", layer: 2, title: "Preferences")
        XCTAssertTrue(isInScope(w))
    }
}
