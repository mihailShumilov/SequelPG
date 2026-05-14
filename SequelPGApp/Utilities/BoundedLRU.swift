import Foundation

/// Bounded least-recently-used cache. Inserting beyond `capacity` evicts the
/// oldest accessed entry. Access (`get`) refreshes recency; `set` also moves
/// the key to the most-recent slot. Not thread-safe — wrap in an actor if used
/// from multiple isolation domains.
///
/// The implementation backs the recency tracking with a `[Key]` array rather
/// than a doubly-linked list. For the small capacities we use here (64–128) the
/// array's O(N) removal is cheaper than the bookkeeping overhead of nodes.
struct BoundedLRU<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "BoundedLRU capacity must be positive")
        self.capacity = capacity
    }

    var count: Int { storage.count }

    /// Returns the value for `key` and marks it most-recently-used.
    mutating func get(_ key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    mutating func set(_ key: Key, _ value: Value) {
        if storage[key] != nil {
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
            }
        } else if storage.count >= capacity {
            let evict = order.removeFirst()
            storage.removeValue(forKey: evict)
        }
        storage[key] = value
        order.append(key)
    }

    mutating func removeValue(forKey key: Key) {
        storage.removeValue(forKey: key)
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
