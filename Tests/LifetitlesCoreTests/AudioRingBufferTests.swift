import Testing
@testable import LifetitlesCore

struct AudioRingBufferTests {
    @Test func returnsEverythingBeforeItFills() {
        var buffer = AudioRingBuffer(capacity: 4)
        buffer.append([1, 2, 3])

        #expect(buffer.snapshot() == [1, 2, 3])
        #expect(buffer.count == 3)
    }

    @Test func keepsOnlyTheNewestSamplesOnceFull() {
        var buffer = AudioRingBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5])

        #expect(buffer.snapshot() == [2, 3, 4, 5])
        #expect(buffer.count == 4)
    }

    @Test func keepsTheEndWhenOneAppendIsLargerThanTheCapacity() {
        var buffer = AudioRingBuffer(capacity: 3)
        buffer.append([1, 2, 3, 4, 5, 6, 7])

        #expect(buffer.snapshot() == [5, 6, 7])
    }

    @Test func startsEmptyAfterRemoveAll() {
        var buffer = AudioRingBuffer(capacity: 3)
        buffer.append([1, 2, 3, 4])
        buffer.removeAll()

        #expect(buffer.snapshot().isEmpty)

        buffer.append([9])
        #expect(buffer.snapshot() == [9])
    }

    @Test func sizesItselfFromADuration() {
        let buffer = AudioRingBuffer(duration: .milliseconds(500))

        #expect(buffer.capacity == 8_000)
    }
}
