import Foundation

/// Executor-confined, deterministic cost-bounded LRU. Reading refreshes recency.
struct DictionaryLRUCache<Key: Hashable, Value> {
    private var values: [Key: (value: Value, cost: Int)] = [:]
    private var order: [Key] = []
    private(set) var totalCost = 0
    let countLimit: Int
    let costLimit: Int
    init(countLimit: Int, costLimit: Int) {
        self.countLimit = countLimit
        self.costLimit = costLimit
    }
    mutating func value(for key: Key) -> Value? {
        guard let item = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key)
        return item.value
    }
    mutating func insert(_ value: Value, for key: Key, cost: Int = 1) {
        if let old = values.removeValue(forKey: key) { totalCost -= old.cost }
        order.removeAll { $0 == key }
        guard cost >= 0, cost <= costLimit, countLimit > 0 else { return }
        values[key] = (value, cost); order.append(key); totalCost += cost
        while values.count > countLimit || totalCost > costLimit {
            let oldest = order.removeFirst()
            if let old = values.removeValue(forKey: oldest) { totalCost -= old.cost }
        }
    }
    mutating func removeAll() { values.removeAll(); order.removeAll(); totalCost = 0 }
}
