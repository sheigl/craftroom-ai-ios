import Foundation

/// Crash cursor for the unattended ladder (build 10).
///
/// Why this exists: on the iPad a jetsam kill inside `MLModel(contentsOf:)`
/// leaves no exception and no crash report. Build 9 therefore restarted the
/// whole 12-cell matrix from cell 1 every time the owner re-opened the app
/// (`auto_default.done` is only written on *full* completion), i.e. a cell that
/// kills the process becomes an infinite crash loop.
///
/// The cursor is the fix: it is written to `Documents/ladder_cursor.json`
/// **before** a cell starts, so after a restart the app knows exactly which
/// cell was in flight. That cell is reported `AUTO-FAIL … reason=process-restart`
/// and the ladder advances. Every cell is attempted at most `maxAttempts` times,
/// so a fresh launch with every cell already failed enumerates nothing and
/// finishes immediately.
///
/// Pure value type: JSON in, JSON out, no file access, no Core ML — the whole
/// advance/skip/exhaust policy is unit-tested here (`LadderCursorTests`).
public struct LadderCursor: Codable, Equatable {
    public enum CellState: String, Codable {
        /// declared by the ladder, never started
        case pending
        /// written before the cell runs — a cursor that still says `started`
        /// after a launch means the process died inside this cell
        case started
        case done
        case failed
        /// never attempted: the memory preflight refused it
        case skipped
    }

    public struct Cell: Codable, Equatable {
        public var label: String
        public var attempts: Int
        public var state: CellState
    }

    /// A cell that is still `started` after a launch gets one retry, then it is
    /// recorded `failed`. Two attempts is the ceiling the run plan asks for.
    public static let defaultMaxAttempts = 2

    /// Identity of the ladder this cursor belongs to (see `ladderID(for:)`).
    public var ladderID: String
    public var cells: [Cell]
    public var maxAttempts: Int

    public init(ladderID: String, labels: [String], maxAttempts: Int = Self.defaultMaxAttempts) {
        self.ladderID = ladderID
        self.cells = labels.map { Cell(label: $0, attempts: 0, state: .pending) }
        self.maxAttempts = max(1, maxAttempts)
    }

    // MARK: identity

    /// Stable, process-independent id for one ladder: `cellCount-<fnv1a64>` in
    /// hex. A re-ordered or edited `auto_default.json` therefore gets a fresh
    /// cursor instead of inheriting the old run's state — and the same ladder
    /// maps to the same id across launches (Swift's `Hasher` is seeded per
    /// process, so it is deliberately not used).
    public static func ladderID(for labels: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in labels.joined(separator: "\u{1f}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return "\(labels.count)-" + String(hash, radix: 16, uppercase: false)
    }

    // MARK: reading

    public var labels: [String] { cells.map(\.label) }

    /// Cells the ladder may still try, in ladder order.
    public func nextIndex() -> Int? {
        cells.firstIndex { $0.state == .pending && $0.attempts < maxAttempts }
    }

    public func nextLabel() -> String? { nextIndex().map { cells[$0].label } }

    /// True when no cell can be attempted any more — the ladder is over,
    /// whether or not anything succeeded. This is what stops a fresh launch
    /// from re-enumerating a dead matrix.
    public var isComplete: Bool {
        !cells.isEmpty && cells.allSatisfy { $0.state != .pending && $0.state != .started }
    }

    public func attempts(_ index: Int) -> Int {
        guard cells.indices.contains(index) else { return 0 }
        return cells[index].attempts
    }

    public func state(_ index: Int) -> CellState? {
        guard cells.indices.contains(index) else { return nil }
        return cells[index].state
    }

    /// Compact one-line state for the log, e.g. `done 3 failed 1 skipped 2 pending 6`.
    public func summary() -> String {
        var counts: [CellState: Int] = [:]
        for c in cells { counts[c.state, default: 0] += 1 }
        let order: [CellState] = [.done, .failed, .skipped, .started, .pending]
        return order.compactMap { s in
            counts[s].map { "\(s.rawValue) \($0)" }
        }.joined(separator: " ")
    }

    // MARK: writing

    /// Marks a cell in flight and returns the 1-based attempt number to log.
    /// Out-of-range indexes return 0 and change nothing.
    @discardableResult
    public mutating func begin(_ index: Int) -> Int {
        guard cells.indices.contains(index) else { return 0 }
        cells[index].attempts += 1
        cells[index].state = .started
        return cells[index].attempts
    }

    /// Records the outcome of an attempted cell.
    public mutating func settle(_ index: Int, _ state: CellState) {
        guard cells.indices.contains(index),
              state == .done || state == .failed || state == .skipped else { return }
        cells[index].state = state
    }

    /// A cell refused by the preflight was never attempted: it counts as
    /// settled without consuming an attempt.
    public mutating func skip(_ index: Int) {
        guard cells.indices.contains(index) else { return }
        cells[index].state = .skipped
    }

    /// What a restart found: one entry per cell that was still `started`.
    /// A cell under the attempt ceiling goes back to `pending` (so the ladder
    /// retries it once); at the ceiling it is recorded `failed`.
    public struct Recovery: Equatable {
        public let index: Int
        public let label: String
        public let attempts: Int
        public let willRetry: Bool
    }

    @discardableResult
    public mutating func recoverAfterRestart() -> [Recovery] {
        var found: [Recovery] = []
        for i in cells.indices where cells[i].state == .started {
            let retry = cells[i].attempts < maxAttempts
            cells[i].state = retry ? .pending : .failed
            found.append(Recovery(index: i, label: cells[i].label,
                                  attempts: cells[i].attempts, willRetry: retry))
        }
        return found
    }

    // MARK: serialisation

    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> LadderCursor {
        try JSONDecoder().decode(LadderCursor.self, from: data)
    }
}
