/// Fixed-capacity buffer; appending past capacity overwrites the oldest element.
public struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var head = 0

    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be > 0")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }

    /// Oldest to newest.
    public var elements: [Element] {
        if storage.count < capacity { return storage }
        return Array(storage[head...] + storage[..<head])
    }

    /// Newest element, if any.
    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count < capacity { return storage[storage.count - 1] }
        return storage[(head + capacity - 1) % capacity]
    }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}
