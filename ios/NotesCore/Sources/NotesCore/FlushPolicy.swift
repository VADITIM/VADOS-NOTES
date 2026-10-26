import Foundation

public struct FlushPolicy: Equatable, Sendable {
    public var idleInterval: TimeInterval
    public var maximumAge: TimeInterval
    public private(set) var firstChange: [String: Date] = [:]
    public private(set) var lastInput: [String: Date] = [:]

    public init(idleInterval: TimeInterval = 5, maximumAge: TimeInterval = 60) {
        self.idleInterval = idleInterval
        self.maximumAge = maximumAge
    }

    public var isDirty: Bool {
        !firstChange.isEmpty
    }

    public mutating func recordInput(page: String, at date: Date) {
        lastInput[page] = date
    }

    public mutating func recordChange(page: String, at date: Date) {
        if firstChange[page] == nil {
            firstChange[page] = date
        }
        lastInput[page] = max(lastInput[page] ?? date, date)
    }

    public func deadline(for page: String) -> Date? {
        guard let first = firstChange[page] else { return nil }
        let idle = (lastInput[page] ?? first).addingTimeInterval(idleInterval)
        return min(idle, first.addingTimeInterval(maximumAge))
    }

    public func nextDeadline() -> Date? {
        firstChange.keys.compactMap { deadline(for: $0) }.min()
    }

    public func isDue(at date: Date) -> Bool {
        guard let next = nextDeadline() else { return false }
        return date >= next
    }

    public mutating func markFlushed() {
        firstChange.removeAll()
        lastInput.removeAll()
    }
}
