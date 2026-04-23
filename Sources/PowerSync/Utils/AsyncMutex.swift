import BasicContainers
import DequeModule

/// A simple async mutex implemented through actors.
actor AsyncMutex<T: ~Copyable> {
    var inner: T
    
    init(_ inner: consuming sending T) {
        self.inner = inner
    }
    
    func withMutex<R>(callback: (_ element: inout T) throws -> R) rethrows -> R {
        try callback(&inner)
    }
}

/// A serialized asynchronous semaphore with associated items.
///
/// Heavily inspired from https://github.com/powersync-ja/powersync-js/blob/main/packages/common/src/utils/mutex.ts.
final class AsyncSemaphore<T: ~Copyable>: Sendable {
    let count: Int
    private let state: Mutex<SemaphoreState<T>>

    init (_ values: consuming RigidDeque<T>) {
        self.count = values.count
        state = Mutex(SemaphoreState(
            available: values
        ))
    }
    
    convenience init(singleElement: consuming T) {
        var queue = RigidDeque<T>(capacity: 1)
        queue.append(singleElement)
        self.init(queue)
    }

    fileprivate func returnItems(items: consuming RigidArray<T>) {
        state.withLock { state in            
            while !items.isEmpty {
                state.returnItem(item: items.removeLast())
            }
        }
    }
    
    func acquire(count: Int) async throws -> SemaphoreGrant<T> {
        precondition(count > 0 && count <= self.count)
        try Task.checkCancellation()
        
        let waiter = Mutex<SemaphoreWaitNode?>(nil)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let node = state.withLock { state in
                    state.addWaiter(requestedItems: count, continuation: continuation)
                }
                
                waiter.withLock { $0 = node }
            }
        }, onCancel: {
            if let waiter = waiter.withLock({ $0 }) {
                state.withLock { state in
                    state.abortWaiter(waiter: waiter)
                }
            }
        })
        
        let node = waiter.withLock { $0! }
        let items: RigidArray<T>? = node.consumeItems()
        if let items, node.isFull {
            return SemaphoreGrant(semaphore: self, items: items)
        } else {
            throw CancellationError()
        }
    }
}

extension AsyncSemaphore where T: Copyable {
    convenience init(from: [T]) {
        var queue = RigidDeque<T>(capacity: from.count)
        for item in from {
            let _ = queue.pushLast(item)
        }
        self.init(queue)
    }
}

struct SemaphoreGrant<T: ~Copyable>: ~Copyable {
    private let semaphore: AsyncSemaphore<T>
    var acquiredItems: RigidArray<T>

    fileprivate init(semaphore: AsyncSemaphore<T>, items: consuming RigidArray<T>) {
        self.semaphore = semaphore
        self.acquiredItems = items
    }

    deinit {
        semaphore.returnItems(items: acquiredItems)
    }
}

private struct SemaphoreState<T: ~Copyable>: ~Copyable {
    // Available items that are not currently assigned to a waiter.
    var available: RigidDeque<T>
    var firstWaiter: SemaphoreWaitNode?
    var lastWaiter: SemaphoreWaitNode?

    var size: Int {
        available.capacity
    }
    
    deinit {
        // Clean up reference cycle in double-linked list.
        var currentNode = firstWaiter
        while let node = currentNode {
            currentNode = node.next
            node.next = nil
            node.prev = nil
        }
    }

    private mutating func deactivateWaiter(waiter: SemaphoreWaitNode) {
        if !waiter.isActive {
            return
        }
        
        waiter.isActive = false
        let prev = waiter.prev
        let next = waiter.next

        if let prev {
            prev.next = next
        }
        if let next {
            next.prev = prev
        }
        
        if waiter === firstWaiter {
            firstWaiter = next
        }
        if waiter === lastWaiter {
            lastWaiter = prev
        }
        
        waiter.continuation.resume(returning: ())
    }

    mutating func returnItem(item: consuming T) {
        // Give it to the next waiter, if possible.
        if let firstWaiter {
            firstWaiter.pushItem(item: item)
            if firstWaiter.isFull {
                self.deactivateWaiter(waiter: firstWaiter)
            }
        } else {
            // No pending waiter, return lease into pool.
            available.append(item)
        }
    }
    
    mutating func returnItems(items: consuming RigidArray<T>) {
        while !items.isEmpty {
            returnItem(item: items.removeLast())
        }
    }
    
    mutating func abortWaiter(waiter: SemaphoreWaitNode) {
        let items: RigidArray<T>? = waiter.consumeItems()
        deactivateWaiter(waiter: waiter)
        if let items {
            returnItems(items: items)
        }
    }
    
    mutating func addWaiter(requestedItems: Int, continuation: CheckedContinuation<(), any Error>) -> SemaphoreWaitNode {
        let node = SemaphoreWaitNode(requestedItems: requestedItems, continuation: continuation)
        if let lastWaiter {
            lastWaiter.next = node
            self.lastWaiter = node
        } else {
            // First waiter
            firstWaiter = node
            lastWaiter = node
        }
        
        // If there are items in the pool that haven't been assigned, we can pull them into this waiter. Note that this is
        // only the case if we're the first waiter (otherwise, items would have been assigned to an earlier waiter).
        while !available.isEmpty && !node.isFull {
            node.pushItem(item: available.removeFirst())
        }
        
        if node.isFull {
            self.deactivateWaiter(waiter: node)
        }
        return node
    }
}

// This isn't actually sendable, but we don't use it concurrently: While waiting, it's only mutated with a lock on SemaphoreState.
// Afterwards, it's sent to acquire() where it's only used in a single async context.
private final class SemaphoreWaitNode: @unchecked Sendable {
    let requestedItems: Int
    var acquiredItems: Int
    var itemsBuffer: UnsafeMutableRawPointer? // pointer to [T; requestedItems]
    var continuation: CheckedContinuation<(), any Error>
    var isActive = true
    var prev: SemaphoreWaitNode?
    var next: SemaphoreWaitNode?

    init(requestedItems: Int, continuation: CheckedContinuation<(), any Error>) {
        self.requestedItems = requestedItems
        self.continuation = continuation
        self.acquiredItems = 0
    }
    
    var isFull: Bool {
        acquiredItems == requestedItems
    }
    
    func pushItem<T: ~Copyable>(item: consuming T) {
        precondition(!isFull)

        if let items = itemsBuffer {
            items.assumingMemoryBound(to: T.self).advanced(by: acquiredItems).initialize(to: item)
        } else {
            let buffer: UnsafeMutablePointer<T> = .allocate(capacity: requestedItems)
            buffer.initialize(to: item)
            
            itemsBuffer = UnsafeMutableRawPointer(buffer)
        }

        acquiredItems += 1
    }

    func consumeItems<T: ~Copyable>() -> RigidArray<T>? {
        if let itemsBuffer {
            var array = RigidArray<T>(capacity: acquiredItems)
            let ptr = UnsafeBufferPointer(start: itemsBuffer.assumingMemoryBound(to: T.self), count: acquiredItems)
            array.insert(moving: UnsafeMutableBufferPointer(mutating: ptr), at: 0)
            // We don't have to deinitialize, array.insert moves elements out of the buffer.
            itemsBuffer.deallocate()
            self.itemsBuffer = nil
            return array
        } else {
            return nil
        }
    }
    
    deinit {
        precondition(itemsBuffer == nil, "Wait node leaked items buffer")
    }
}
