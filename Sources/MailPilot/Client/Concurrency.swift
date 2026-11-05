import Foundation

/// Führt `body` für alle Elemente aus, höchstens `limit` gleichzeitig. Kehrt zurück, wenn alle fertig sind.
/// Gedacht für den Abgleich mehrerer Konten: ein langsames oder hängendes Konto hält die anderen nicht auf.
func forEachConcurrently<T: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async -> Void) async {
    guard !items.isEmpty else { return }
    await withTaskGroup(of: Void.self) { group in
        var next = 0
        func startNext() {
            guard next < items.count else { return }
            let item = items[next]
            next += 1
            group.addTask { await body(item) }
        }
        for _ in 0..<min(max(limit, 1), items.count) { startNext() }
        while await group.next() != nil { startNext() }
    }
}
