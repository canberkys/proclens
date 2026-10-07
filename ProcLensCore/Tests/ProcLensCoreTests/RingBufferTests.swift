import Testing
@testable import ProcLensCore

struct RingBufferTests {
    @Test func appendsInOrderBelowCapacity() {
        var b = RingBuffer<Int>(capacity: 3)
        #expect(b.last == nil)
        b.append(1); b.append(2)
        #expect(b.elements == [1, 2])
        #expect(b.count == 2)
        #expect(b.last == 2)
    }

    @Test func wrapsAroundOverwritingOldest() {
        var b = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { b.append(i) }
        #expect(b.elements == [3, 4, 5])
        #expect(b.count == 3)
        #expect(b.last == 5)
        b.append(6)
        #expect(b.elements == [4, 5, 6])
    }

    @Test func capacityOne() {
        var b = RingBuffer<String>(capacity: 1)
        b.append("a"); b.append("b")
        #expect(b.elements == ["b"])
        #expect(b.last == "b")
        #expect(b.capacity == 1)
    }

    @Test func removeAllResets() {
        var b = RingBuffer<Int>(capacity: 2)
        for i in 1...3 { b.append(i) }
        b.removeAll()
        #expect(b.count == 0)
        #expect(b.elements.isEmpty)
        b.append(9)
        #expect(b.elements == [9])
    }
}
