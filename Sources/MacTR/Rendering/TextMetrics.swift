// TextMetrics.swift — memoized text measurement
//
// Measuring a string is the single most expensive thing the renderer does, and
// almost all of it is repeated work: the dashboard redraws 2-4 times a second
// while its data changes every couple of seconds, so the same labels, units and
// project names are measured over and over to arrive at the same answer.
//
// Nothing here changes what is drawn. Every cached function is pure — same
// string, same font, same width — so a hit is indistinguishable from a miss
// apart from the time it takes.

import AppKit
import Foundation

/// Bounded memo table. Computing happens outside the lock, so two threads
/// racing on a cold key both compute and both store the same value; that is
/// cheaper than holding the lock across a measurement and is only safe because
/// every value stored here is a pure function of its key.
///
/// At capacity the table is emptied rather than evicted one entry at a time.
/// The contents are one screen's worth of strings, so the cliff refills within
/// a frame or two, and this avoids paying for LRU bookkeeping on every hit.
final class MemoCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Key: Value]

    init(capacity: Int) {
        self.capacity = capacity
        self.entries = Dictionary(minimumCapacity: capacity / 4)
    }

    func value(for key: Key, make: () -> Value) -> Value {
        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let made = make()

        lock.lock()
        if entries.count >= capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = made
        lock.unlock()
        return made
    }

    /// Test seam: lets a test observe that a second call was a hit.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

enum TextMetrics {
    /// Fonts are compared by name and size rather than by object identity:
    /// `Fonts` hands out shared instances, but a caller measuring with a font it
    /// built itself must still hit the same entry.
    private struct SizeKey: Hashable {
        let text: String
        let fontName: String
        let pointSize: CGFloat
    }

    /// Roughly a hundred strings are drawn per frame and the set turns over
    /// slowly, so this holds many frames' worth without ever filling up in
    /// normal use.
    private static let sizes = MemoCache<SizeKey, CGSize>(capacity: 4096)

    static func size(of text: String, font: NSFont) -> CGSize {
        sizes.value(
            for: SizeKey(
                text: text, fontName: font.fontName, pointSize: font.pointSize)
        ) {
            (text as NSString).size(withAttributes: [.font: font])
        }
    }

    static func width(of text: String, font: NSFont) -> CGFloat {
        size(of: text, font: font).width
    }
}
