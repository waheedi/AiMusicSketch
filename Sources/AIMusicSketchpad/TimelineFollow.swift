import Foundation

struct TimelineViewport: Equatable {
    var offset = 0.0
    var width = 0.0
    var contentWidth = 0.0
}

enum TimelineFollow {
    /// Move before the cursor leaves the viewport, keeping a quarter-screen of
    /// context behind it. Pixel geometry makes this independent of bars or zoom.
    static func target(playheadX: Double, viewport: TimelineViewport,
                       enabled: Bool, playing: Bool, force: Bool = false) -> Double? {
        guard enabled, playing || force, playheadX.isFinite,
              viewport.width.isFinite, viewport.width > 40,
              viewport.offset.isFinite, viewport.contentWidth.isFinite else { return nil }
        let left = max(0, viewport.offset)
        if !force && playheadX >= left + 12 && playheadX <= left + viewport.width * 0.8 { return nil }
        let target = min(max(0, viewport.contentWidth - viewport.width), max(0, playheadX - viewport.width * 0.25))
        return abs(target - left) >= 1 ? target : nil
    }
}
