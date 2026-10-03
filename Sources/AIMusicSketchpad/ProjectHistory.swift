import Foundation

/// Value snapshots retain asset references, never duplicate or delete recorded audio.
struct ProjectHistory {
    struct Entry {
        var before: StudioProject
        var after: StudioProject
        var title: String
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var undoTitle: String { past.last?.title ?? "" }
    var redoTitle: String { future.last?.title ?? "" }

    mutating func record(before: StudioProject, after: StudioProject, title: String) {
        guard before != after else { return }
        past.append(Entry(before: before, after: after, title: title))
        if past.count > 100 { past.removeFirst(past.count - 100) }
        future.removeAll()
    }
    mutating func undo() -> StudioProject? {
        guard let entry = past.popLast() else { return nil }
        future.append(entry)
        return entry.before
    }
    mutating func redo() -> StudioProject? {
        guard let entry = future.popLast() else { return nil }
        past.append(entry)
        return entry.after
    }
}
