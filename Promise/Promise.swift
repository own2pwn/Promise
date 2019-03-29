//
//  Promise.swift
//  Promise
//
//  Created by Soroush Khanlou on 7/21/16.
//
//

import Foundation
#if os(Linux)
    import Dispatch
#endif

public protocol ExecutionContext {
    func execute(_ work: @escaping () -> Void)
}

extension DispatchQueue: ExecutionContext {
    public func execute(_ work: @escaping () -> Void) {
        async(execute: work)
    }
}

public final class InvalidatableQueue: ExecutionContext {
    private var valid = true

    private var queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func invalidate() {
        valid = false
    }

    public func execute(_ work: @escaping () -> Void) {
        guard valid else { return }
        queue.async(execute: work)
    }
}

struct Callback<Value> {
    let onFulfilled: (Value) -> Void
    let onRejected: (Error) -> Void
    let executionContext: ExecutionContext

    func callFulfill(_ value: Value, completion: @escaping () -> Void = {}) {
        executionContext.execute {
            self.onFulfilled(value)
            completion()
        }
    }

    func callReject(_ error: Error, completion: @escaping () -> Void = {}) {
        executionContext.execute {
            self.onRejected(error)
            completion()
        }
    }
}

enum State<Value>: CustomStringConvertible {
    /// The promise has not completed yet.
    /// Will transition to either the `fulfilled` or `rejected` state.
    case alive(callbacks: [Callback<Value>])

    /// The promise now has a value.
    /// Will not transition to any other state.
    case fulfilled(value: Value)

    /// The promise failed with the included error.
    /// Will not transition to any other state.
    case rejected(error: Error)

    /// Won't accept values and call callbacks.
    case sealed

    var isPending: Bool {
        if case .alive = self {
            return true
        } else {
            return false
        }
    }

    var isFulfilled: Bool {
        if case .fulfilled = self {
            return true
        } else {
            return false
        }
    }

    var isRejected: Bool {
        if case .rejected = self {
            return true
        } else {
            return false
        }
    }

    var value: Value? {
        if case let .fulfilled(value) = self {
            return value
        }
        return nil
    }

    var error: Error? {
        if case let .rejected(error) = self {
            return error
        }
        return nil
    }

    var isSealed: Bool {
        if case .sealed = self {
            return true
        }
        return false
    }

    var isAlive: Bool {
        return !isSealed && !isRejected
    }

    var callbacks: [Callback<Value>] {
        if case let .alive(callbacks) = self {
            return callbacks
        }
        return []
    }

    var description: String {
        switch self {
        case let .fulfilled(value):
            return "Fulfilled (\(value))"
        case let .rejected(error):
            return "Rejected (\(error))"
        case .alive:
            return "Alive"
        case .sealed:
            return "Sealed"
        }
    }
}

public class Promise<Value> {
    fileprivate var state: State<Value>
    fileprivate var lockQueue: DispatchQueue = DispatchQueue(label: "promise_lock_queue", qos: .userInitiated)
    fileprivate var workingQueue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)

    public init() {
        state = .alive(callbacks: [])
        setup()
    }

    public init(value: Value) {
        state = .fulfilled(value: value)
        setup()
    }

    public init(error: Error) {
        state = .rejected(error: error)
        setup()
    }

    func setup() {}

    public convenience init(queue: DispatchQueue? = nil, work: @escaping (_ fulfill: @escaping (Value) -> Void, _ reject: @escaping (Error) -> Void) throws -> Void) {
        self.init()
        let q: DispatchQueue = queue ?? workingQueue

        q.async {
            do {
                try work(self.fulfill, self.reject)
            } catch {
                self.reject(error)
            }
        }
    }

    /// - note: This one is "flatMap"
    @discardableResult
    public func then<NewValue>(on queue: ExecutionContext? = nil, _ onFulfilled: @escaping (Value) throws -> Promise<NewValue>) -> Promise<NewValue> {
        let exec: ExecutionContext = queue ?? workingQueue

        return Promise<NewValue>(work: { fulfill, reject in
            self.addCallbacks(
                on: exec,
                onFulfilled: { value in
                    do {
                        try onFulfilled(value).then(on: queue, fulfill, reject)
                    } catch {
                        reject(error)
                    }
                },
                onRejected: reject
            )
        })
    }

    /// - note: This one is "map"
    @discardableResult
    public func then<NewValue>(on queue: ExecutionContext? = nil, _ onFulfilled: @escaping (Value) throws -> NewValue) -> Promise<NewValue> {
        let exec: ExecutionContext = queue ?? workingQueue

        return then(on: exec, { (value) -> Promise<NewValue> in
            do {
                return Promise<NewValue>(value: try onFulfilled(value))
            } catch {
                return Promise<NewValue>(error: error)
            }
        })
    }

    /// - note: This one will be called on main thread.
    @discardableResult
    @inlinable
    public func display<NewValue>(_ onFulfilled: @escaping (Value) throws -> NewValue) -> Promise<NewValue> {
        return then(on: DispatchQueue.main, onFulfilled)
    }

    @discardableResult
    public func then(on queue: ExecutionContext? = nil, _ onFulfilled: @escaping (Value) -> Void, _ onRejected: @escaping (Error) -> Void = { _ in }) -> Promise<Value> {
        let exec: ExecutionContext = queue ?? workingQueue

        addCallbacks(on: exec, onFulfilled: onFulfilled, onRejected: onRejected)
        return self
    }

    @discardableResult
    public func `catch`(on queue: ExecutionContext? = nil, _ onRejected: @escaping (Error) -> Void) -> Promise<Value> {
        let exec: ExecutionContext = queue ?? workingQueue

        return then(on: exec, { _ in }, onRejected)
    }

    public func reject(_ error: Error) {
        updateState(.rejected(error: error))
    }

    public func fulfill(_ value: Value) {
        updateState(.fulfilled(value: value))
    }

    public var isPending: Bool {
        return !isFulfilled && !isRejected
    }

    public var isFulfilled: Bool {
        return value != nil
    }

    public var isRejected: Bool {
        return error != nil
    }

    public var value: Value? {
        return lockQueue.sync {
            self.state.value
        }
    }

    public var error: Error? {
        return lockQueue.sync {
            self.state.error
        }
    }

    private func updateState(_ newState: State<Value>) {
        lockQueue.async {
            guard case let .alive(callbacks) = self.state else { return }
            self.state = newState
            self.fireIfCompleted(callbacks: callbacks)
        }
    }

    private func addCallbacks(on queue: ExecutionContext? = nil, onFulfilled: @escaping (Value) -> Void, onRejected: @escaping (Error) -> Void) {
        let exec: ExecutionContext = queue ?? workingQueue

        let callback = Callback(onFulfilled: onFulfilled, onRejected: onRejected, executionContext: exec)
        lockQueue.async(flags: .barrier) {
            switch self.state {
            case let .alive(callbacks):
                self.state = .alive(callbacks: callbacks + [callback])
            case let .fulfilled(value):
                callback.callFulfill(value)
            case let .rejected(error):
                callback.callReject(error)
            case .sealed:
                break
            }
        }
    }

    private func fireIfCompleted(callbacks: [Callback<Value>]) {
        guard !callbacks.isEmpty else {
            return
        }
        lockQueue.async {
            switch self.state {
            case .alive, .sealed:
                break
            case let .fulfilled(value):
                var mutableCallbacks = callbacks
                let firstCallback = mutableCallbacks.removeFirst()
                firstCallback.callFulfill(value) {
                    self.fireIfCompleted(callbacks: mutableCallbacks)
                }
            case let .rejected(error):
                var mutableCallbacks = callbacks
                let firstCallback = mutableCallbacks.removeFirst()
                firstCallback.callReject(error) {
                    self.fireIfCompleted(callbacks: mutableCallbacks)
                }
            }
        }
    }
}

public final class MPromise<Value>: Promise<Value> {
    // MARK: - Interface

    public override func fulfill(_ value: Value) {
        lockQueue.async {
            guard self.state.isAlive else { return }
            self.fireIfCompleted(
                callbacks: self.state.callbacks,
                with: value
            )
        }
    }

    // MARK: - Overrides

    override func setup() {
        lockQueue = DispatchQueue(
            label: "m_promise_lock_queue",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    // MARK: - Helpers

    private func fireIfCompleted(callbacks: [Callback<Value>], with value: Value) {
        guard !callbacks.isEmpty else {
            return
        }
        lockQueue.async {
            switch self.state {
            case .fulfilled:
                fatalError()
            case .sealed:
                break
            case .alive:
                var mutableCallbacks = callbacks
                let firstCallback = mutableCallbacks.removeFirst()
                firstCallback.callFulfill(value) {
                    self.fireIfCompleted(callbacks: mutableCallbacks, with: value)
                }
            case let .rejected(error):
                var mutableCallbacks = callbacks
                let firstCallback = mutableCallbacks.removeFirst()
                firstCallback.callReject(error) {
                    self.fireIfCompleted(callbacks: mutableCallbacks, with: value)
                }
            }
        }
    }
}
