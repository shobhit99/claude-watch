import Foundation

/// A generic, thread-safe ring buffer with a configurable capacity.
/// When the buffer is full, the oldest item is overwritten on append.
final class OutputRingBuffer<T> {

    private let capacity: Int
    private var buffer: [T]
    private var head: Int = 0     // Next write position
    private var isFull: Bool = false
    private let lock = NSLock()

    /// Creates a ring buffer with the given maximum capacity.
    /// - Parameter capacity: The maximum number of items the buffer can hold.
    init(capacity: Int) {
        precondition(capacity > 0, "OutputRingBuffer capacity must be greater than 0")
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
    }

    /// The current number of items in the buffer.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return isFull ? capacity : head
    }

    /// Appends a new item to the buffer, evicting the oldest item if at capacity.
    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }

        if buffer.count < capacity {
            // Still filling the initial buffer
            buffer.append(item)
            head = buffer.count
            if head == capacity {
                head = 0
                isFull = true
            }
        } else {
            // Buffer is at capacity; overwrite the oldest element
            buffer[head] = item
            head = (head + 1) % capacity
            isFull = true
        }
    }

    /// Returns all items in order from oldest to newest.
    func getAll() -> [T] {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return [] }

        if !isFull {
            // Buffer hasn't wrapped yet
            return Array(buffer[0..<head])
        }

        // Buffer has wrapped: oldest items start at head
        return Array(buffer[head..<buffer.count]) + Array(buffer[0..<head])
    }

    /// Returns the last `count` items in order from oldest to newest.
    /// If `count` exceeds the number of stored items, all items are returned.
    func getLast(_ requestedCount: Int) -> [T] {
        let all = getAll()
        guard requestedCount < all.count else { return all }
        return Array(all.suffix(requestedCount))
    }

    /// Removes all items from the buffer.
    func clear() {
        lock.lock()
        defer { lock.unlock() }

        buffer.removeAll(keepingCapacity: true)
        head = 0
        isFull = false
    }
}
