import Foundation

public protocol DateProvider: Sendable {
    func now() -> Date
}

public struct SystemDateProvider: DateProvider {
    public init() {}
    public func now() -> Date { Date() }
}

/// For tests: advance `currentDate` manually to simulate time passage.
public final class TestDateProvider: DateProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date
    public init(startingAt: Date) { self.currentDate = startingAt }
    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return currentDate }
    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        currentDate = currentDate.addingTimeInterval(seconds)
    }
    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        currentDate = date
    }
}
