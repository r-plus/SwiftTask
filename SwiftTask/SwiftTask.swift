//
//  SwiftTask.swift
//  SwiftTask
//
//  Created by Yasuhiro Inami on 2014/08/21.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

// Required for use in the playground Sources folder
import ObjectiveC

public enum SwiftTaskQueue: Equatable {
    case main
    case userInteractive
    case userInitiated
    case utility
    case background
    case custom(queue: DispatchQueue)
    case current
    
    var queue: DispatchQueue {
        switch self {
        case .main: return .main
        case .userInteractive: return .global(qos: .userInteractive)
        case .userInitiated: return .global(qos: .userInitiated)
        case .utility: return .global(qos: .utility)
        case .background: return .global(qos: .background)
        case .custom(let queue): return queue
        case .current: fatalError("use current thread serially.")
        }
    }
}

// NOTE: nested type inside generic Task class is not allowed in Swift 1.1
public enum TaskState: String, CustomStringConvertible
{
    case Paused = "Paused"
    case Running = "Running"
    case Fulfilled = "Fulfilled"
    case Rejected = "Rejected"
    case Cancelled = "Cancelled"
    
    public var description: String
    {
        return self.rawValue
    }
}

// NOTE: use class instead of struct to pass reference to `_initClosure` to set `pause`/`resume`/`cancel` closures
public class TaskConfiguration
{
    public var pause: (() -> Void)?
    public var resume: (() -> Void)?
    public var cancel: (() -> Void)?
    public var retryCount = 0
    #if DEBUG
    public var isChained = false
    #endif
    
    /// useful to terminate immediate-infinite-sequence while performing `initClosure`
    public var isFinished : Bool
    {
        return self._isFinished.rawValue
    }
    
    private var _isFinished = _Atomic(false)
    
    internal func finish()
    {
        //
        // Cancel anyway on task finished (fulfilled/rejected/cancelled).
        //
        // NOTE:
        // ReactKit uses this closure to call `upstreamSignal.cancel()`
        // and let it know `configure.isFinished = true` while performing its `initClosure`.
        //
        self.cancel?()
        
        self.pause = nil
        self.resume = nil
        self.cancel = nil
        self._isFinished.rawValue = true
    }
}

#if DEBUG
var gcount = 0
#endif

open class Task<Value, Error>: Cancellable, CustomStringConvertible
{
    #if DEBUG
    public var icount = 0
    #endif
    
    public typealias ErrorInfo = (error: Error?, isCancelled: Bool)
    
    public typealias FulfillHandler = (Value) -> Void
    public typealias RejectHandler = (Error) -> Void
    public typealias Configuration = TaskConfiguration
    
    public typealias PromiseInitClosure = (_ fulfill: @escaping FulfillHandler, _ reject: @escaping RejectHandler) -> Void
    public typealias InitClosure = (_ fulfill: @escaping FulfillHandler, _ reject: @escaping RejectHandler, _ configure: TaskConfiguration) -> Void
    
    internal typealias _Machine = _StateMachine<Value, Error>
    
    internal typealias _InitClosure = (_ machine: _Machine, _ fulfill: @escaping FulfillHandler, _ _reject: @escaping _RejectInfoHandler, _ configure: TaskConfiguration) -> Void
    
    internal typealias _RejectInfoHandler = (ErrorInfo) -> Void
    
    internal let _machine: _Machine
    
    // store initial parameters for cloning task when using `try()`
    internal let _paused: Bool
    internal var _initClosure: _InitClosure!    // retained throughout task's lifetime
    
    public var state: TaskState { return self._machine.state.rawValue }
        
    /// fulfilled value
    public var value: Value? { return self._machine.value.rawValue }
    
    /// rejected/cancelled tuple info
    public var errorInfo: ErrorInfo? { return self._machine.errorInfo.rawValue }
    
    public private(set) var name: String = "DefaultTask"
    
    open var description: String
    {
        var valueString: String?
        
        switch (self.state) {
            case .Fulfilled:
                valueString = "value=\(self.value!)"
            case .Rejected, .Cancelled:
                valueString = "errorInfo=\(self.errorInfo!)"
            default:
                valueString = ""
        }
        
        return "<\(self.name); state=\(self.state.rawValue); \(valueString!))>"
    }
    
    /// Value type converted to Void task that useful when multiple tasks that have different Value type pass to `all` method.
    public var voidTask: Task<Void, Error> {
        // Use on(failure) method to chain Cancelled state to upstream(self).
        return self.success { (_) -> Void in }.on(failure: { [weak self] (err, isCancelled) in
            guard let _self = self, isCancelled else { return }
            _self.cancel()
        })
    }
    
    /// convert to fulfilled task for `allSettled` function.
    internal var settled: Task<Void, Error> {
        return self.success { (value) -> Void in
        }.failure { (err, isCancelled) -> Void in
        }
    }

    // MARK: - init
    
    ///
    /// Create a new task.
    ///
    /// - e.g. Task<P, V, E>(weakified: false, paused: false) { progress, fulfill, reject, configure in ... }
    ///
    /// - Parameter paused: Flag to invoke `initClosure` immediately or not. If `paused = true`, task's initial state will be `.Paused` and needs to `resume()` in order to start `.Running`. If `paused = false`, `initClosure` will be invoked immediately.
    ///
    /// - Parameter initClosure: e.g. { progress, fulfill, reject, configure in ... }. `fulfill(value)` and `reject(error)` handlers must be called inside this closure, where calling `progress(progressValue)` handler is optional. Also as options, `configure.pause`/`configure.resume`/`configure.cancel` closures can be set to gain control from outside e.g. `task.pause()`/`task.resume()`/`task.cancel()`. When using `configure`, make sure to use weak modifier when appropriate to avoid "task -> player" retaining which often causes retain cycle.
    ///
    /// - Returns: New task.
    ///
    public init(on queue: SwiftTaskQueue = .current, paused: Bool = false, initClosure: @escaping InitClosure)
    {
        self._paused = paused
        self._machine = _Machine(on: queue, paused: paused)
        
        let _initClosure: _InitClosure = { _, fulfill, _reject, configure in
            // NOTE: don't expose rejectHandler with ErrorInfo (isCancelled) for public init
            initClosure(fulfill, { error in _reject(ErrorInfo(error: Optional(error), isCancelled: false)) }, configure)
        }
        
        self.setup(on: queue, paused: paused, _initClosure: _initClosure)
    }
    
    ///
    /// Create fulfilled task (non-paused)
    ///
    /// - e.g. Task<P, V, E>(value: someValue)
    ///
    public convenience init(value: Value)
    {
        self.init(initClosure: { fulfill, reject, configure in
            fulfill(value)
        })
        self.name = "FulfilledTask"
    }
    
    ///
    /// Create rejected task (non-paused)
    ///
    /// - e.g. Task<P, V, E>(error: someError)
    ///
    public convenience init(error: Error)
    {
        self.init(initClosure: { fulfill, reject, configure in
            reject(error)
        })
        self.name = "RejectedTask"
    }
    
    private convenience init(_errorInfo: ErrorInfo)
    {
        self.init(_initClosure: { _, fulfill, _reject, configure in
            _reject(_errorInfo)
        })
        self.name = "RejectedTask"
    }
    
    /// private-init for accessing `machine` inside `_initClosure`
    /// (NOTE: _initClosure has _RejectInfoHandler as argument)
    fileprivate init(on queue: SwiftTaskQueue = .current, paused: Bool = false, _initClosure: @escaping _InitClosure)
    {
        self._paused = paused
        self._machine = _Machine(on: queue, paused: paused)
        
        self.setup(on: queue, paused: paused, _initClosure: _initClosure)
    }
    
    // NOTE: don't use `internal init` for this setup method, or this will be a designated initializer
    private func setup(on queue: SwiftTaskQueue, paused: Bool, _initClosure: @escaping _InitClosure)
    {
        #if DEBUG
            gcount += 1
            icount = gcount
            let addr = ObjectIdentifier(self)
            print("[init] \(self.name) \(addr) \(icount)")
        #endif
        
        self._initClosure = _initClosure
        
        // will be invoked on 1st resume (only once)
        self._machine.initResumeClosure.rawValue = {
            let fulfillHandler: FulfillHandler = { (value: Value) in
                self._machine.handleFulfill(value)
            }
            let rejectInfoHandler: _RejectInfoHandler = { (errorInfo: ErrorInfo) in
                self._machine.handleRejectInfo(errorInfo)
            }

            if queue == .current {
                _initClosure(self._machine, fulfillHandler, rejectInfoHandler, self._machine.configuration)
            } else {
                queue.queue.async {
                    _initClosure(self._machine, fulfillHandler, rejectInfoHandler, self._machine.configuration)
                }
            }
        }
        
        if !paused {
            self.resume()
        }
    }
    
    deinit
    {
        #if DEBUG
            let addr = ObjectIdentifier(self)
            print("[deinit] \(self.name) \(addr) \(icount)")
        #endif
        
        // cancel in case machine is still running
        self.cancel(error: nil)
    }
    
    /// Sets task name (method chainable)
    public func name(_ name: String) -> Self
    {
        self.name = name
        return self
    }
    
    // MARK: - clone
    
    /// Creates cloned task.
    public func clone() -> Task
    {
        let clonedTask = Task(on: _machine.queue, paused: self._paused, _initClosure: self._initClosure)
        clonedTask.name = "\(self.name)-clone"
        return clonedTask
    }
    
    private func pausedClone() -> Task {
        let clonedTask = Task(on: _machine.queue, paused: true, _initClosure: self._initClosure)
        clonedTask.name = "\(self.name)-clone"
        return clonedTask
    }
    
    // MARK: - retry
    
    /// Returns new task that is retryable for `maxRetryCount (= maxTryCount-1)` times.
    /// - Parameter condition: Predicate that will be evaluated on each retry timing.
    public func retry(_ maxRetryCount: Int, condition: @escaping ((ErrorInfo) -> Bool) = { _ in true }) -> Task
    {
        #if DEBUG
            assert(!self._machine.configuration.isChained, "Don't retry chained task.")
        #endif
        guard maxRetryCount > 0 else { return self }
        
        return Task { machine, fulfill, _reject, configure in
            
//            let task = self.progress { _, progressValue in
//                progress(progressValue)
            let task = self.failure { [unowned self] errorInfo -> Task in
                guard !errorInfo.isCancelled else {
                    return Task(_errorInfo: errorInfo)
                }
                if condition(errorInfo) {
                    // should pausedClone to correctlly count up retryCount in initClosure and support paused init task.
                    let clone = self.pausedClone()
                    clone._machine.configuration.retryCount = self._machine.configuration.retryCount + 1
                    clone.resume()
                    return clone.retry(maxRetryCount-1, condition: condition) // clone & try recursively
                }
                else {
                    return Task(_errorInfo: errorInfo)
                }
            }
                
//            task.progress { _, progressValue in
//                progress(progressValue) // also receive progresses from clone-try-task
            task.success { value -> Void in
                fulfill(value)
            }.failure { errorInfo -> Void in
                _reject(errorInfo)
            }
            
            configure.pause = {
                self.pause()
                task.pause()
            }
            configure.resume = {
                self.resume()
                task.resume()
            }
            configure.cancel = {
                task.cancel()   // cancel downstream first
                self.cancel()
            }
            
        }.name("\(self.name)-try(\(maxRetryCount))")
    }
    
    // MARK: - then
    
    ///
    /// `then` (fulfilled & rejected) + closure returning **value**.
    /// (similar to `map` in functional programming)
    ///
    /// - e.g. task.then { value, errorInfo -> NextValueType in ... }
    ///
    /// - Returns: New `Task`
    ///
    @discardableResult func then<Value2>(on queue: SwiftTaskQueue, _ thenClosure: @escaping (Value?, ErrorInfo?) -> Value2) -> Task<Value2, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.then(on: queue, &dummyCanceller, thenClosure)
    }
    
    func then<Value2, C: Canceller>(on queue: SwiftTaskQueue, _ canceller: inout C?, _ thenClosure: @escaping (Value?, ErrorInfo?) -> Value2) -> Task<Value2, Error>
    {
        return self.then(on: queue, &canceller) { (value, errorInfo) -> Task<Value2, Error> in
            return Task<Value2, Error>(value: thenClosure(value, errorInfo))
        }
    }
    
    ///
    /// `then` (fulfilled & rejected) + closure returning **task**.
    /// (similar to `flatMap` in functional programming)
    ///
    /// - e.g. task.then { value, errorInfo -> NextTaskType in ... }
    ///
    /// - Returns: New `Task`
    ///
    func then<Value2, Error2>(on queue: SwiftTaskQueue, _ thenClosure: @escaping (Value?, ErrorInfo?) -> Task<Value2, Error2>) -> Task<Value2, Error2>
    {
        var dummyCanceller: Canceller? = nil
        return self.then(on: queue, &dummyCanceller, thenClosure)
    }
    
    //
    // NOTE: then-canceller is a shorthand of `task.cancel(nil)`, i.e. these two are the same:
    //
    // - `let canceller = Canceller(); task1.then(&canceller) {...}; canceller.cancel();`
    // - `let task2 = task1.then {...}; task2.cancel();`
    //
    /// - Returns: New `Task`
    ///
    func then<Value2, Error2, C: Canceller>(on queue: SwiftTaskQueue, _ canceller: inout C?, _ thenClosure: @escaping (Value?, ErrorInfo?) -> Task<Value2, Error2>) -> Task<Value2, Error2>
    {
        return Task<Value2, Error2>(on: queue) { [unowned self, weak canceller] newMachine, fulfill, _reject, configure in
            
            //
            // NOTE: 
            // We split `self` (Task) and `self.machine` (StateMachine) separately to
            // let `completionHandler` retain `selfMachine` instead of `self`
            // so that `selfMachine`'s `completionHandlers` can be invoked even though `self` is deinited.
            // This is especially important for ReactKit's `deinitSignal` behavior.
            //
            let selfMachine = self._machine
            
            self._then(on: queue, &canceller) {
                let innerTask = thenClosure(selfMachine.value.rawValue, selfMachine.errorInfo.rawValue)
                _bindInnerTask(innerTask, newMachine, fulfill, _reject, configure)
            }
            
        }.name("\(self.name)-then")
    }

    /// invokes `completionHandler` "now" or "in the future"
    private func _then<C: Canceller>(on queue: SwiftTaskQueue, _ canceller: inout C?, _ completionHandler: @escaping () -> Void)
    {
        switch self.state {
            case .Fulfilled, .Rejected, .Cancelled:
                if queue == .current {
                    completionHandler()
                } else {
                    queue.queue.async {
                        completionHandler()
                    }
                }
            default:
                var token: _HandlerToken? = nil
                self._machine.addCompletionHandler(queue, &token, completionHandler)
            
                canceller = C { [weak self] in
                    self?._machine.removeCompletionHandler(token)
                }
        }
    }
    
    // MARK: - success
    
    ///
    /// `success` (fulfilled) + closure returning **value**.
    /// (synonym for `map` in functional programming)
    ///
    /// - e.g. task.success { value -> NextValueType in ... }
    ///
    /// - Returns: New `Task`
    ///
    @discardableResult public func success<Value2>(on queue: SwiftTaskQueue = .current, _ successClosure: @escaping (Value) -> Value2) -> Task<Value2, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.success(on: queue, &dummyCanceller, successClosure)
    }
    
    public func success<Value2, C: Canceller>(on queue: SwiftTaskQueue = .current, _ canceller: inout C?, _ successClosure: @escaping (Value) -> Value2) -> Task<Value2, Error>
    {
        return self.success(on: queue, &canceller) { (value: Value) -> Task<Value2, Error> in
            return Task<Value2, Error>(value: successClosure(value))
        }
    }
    
    ///
    /// `success` (fulfilled) + closure returning **task**
    /// (synonym for `flatMap` in functional programming)
    ///
    /// - e.g. task.success { value -> NextTaskType in ... }
    ///
    /// - Returns: New `Task`
    ///
    public func success<Value2, Error2>(on queue: SwiftTaskQueue = .current, _ successClosure: @escaping (Value) -> Task<Value2, Error2>) -> Task<Value2, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.success(on: queue, &dummyCanceller, successClosure)
    }
    
    public func success<Value2, Error2, C: Canceller>(on queue: SwiftTaskQueue = .current, _ canceller: inout C?, _ successClosure: @escaping (Value) -> Task<Value2, Error2>) -> Task<Value2, Error>
    {
        var localCanceller = canceller; defer { canceller = localCanceller }
        let newQueue = queue == .current ? _machine.queue : queue
        return Task<Value2, Error>(on: newQueue) { newMachine, fulfill, _reject, configure in
            
            #if DEBUG
                configure.isChained = true
            #endif
            
            let selfMachine = self._machine

            // NOTE: using `self._then()` + `selfMachine` instead of `self.then()` will reduce Task allocation
            self._then(on: newQueue, &localCanceller) {
                if let value = selfMachine.value.rawValue {
                    let innerTask = successClosure(value)
                    _bindInnerTask(innerTask, newMachine, fulfill, _reject, configure)
                }
                else if let errorInfo = selfMachine.errorInfo.rawValue {
                    _reject(errorInfo)
                }
            }
            
        }.name("\(self.name)-success")
    }
    
    // MARK: - failure
    
    ///
    /// `failure` (rejected or cancelled) + closure returning **value**.
    /// (synonym for `mapError` in functional programming)
    ///
    /// - e.g. task.failure { errorInfo -> NextValueType in ... }
    /// - e.g. task.failure { error, isCancelled -> NextValueType in ... }
    ///
    /// - Returns: New `Task`
    ///
    @discardableResult public func failure(on queue: SwiftTaskQueue = .current, _ failureClosure: @escaping (ErrorInfo) -> Value) -> Task
    {
        var dummyCanceller: Canceller? = nil
        return self.failure(on: queue, &dummyCanceller, failureClosure)
    }
    
    public func failure<C: Canceller>(on queue: SwiftTaskQueue = .current, _ canceller: inout C?, _ failureClosure: @escaping (ErrorInfo) -> Value) -> Task
    {
        return self.failure(on: queue, &canceller) { (errorInfo: ErrorInfo) -> Task in
            return Task(value: failureClosure(errorInfo))
        }
    }

    ///
    /// `failure` (rejected or cancelled) + closure returning **task**.
    /// (synonym for `flatMapError` in functional programming)
    ///
    /// - e.g. task.failure { errorInfo -> NextTaskType in ... }
    /// - e.g. task.failure { error, isCancelled -> NextTaskType in ... }
    ///
    /// - Returns: New `Task`
    ///
    public func failure<Error2>(on queue: SwiftTaskQueue = .current, _ failureClosure: @escaping (ErrorInfo) -> Task<Value, Error2>) -> Task<Value, Error2>
    {
        var dummyCanceller: Canceller? = nil
        return self.failure(on: queue, &dummyCanceller, failureClosure)
    }
    
    public func failure<Error2, C: Canceller>(on queue: SwiftTaskQueue = .current, _ canceller: inout C?, _ failureClosure: @escaping (ErrorInfo) -> Task<Value, Error2>) -> Task<Value, Error2>
    {
        var localCanceller = canceller; defer { canceller = localCanceller }
        let newQueue = queue == .current ? _machine.queue : queue
        return Task<Value, Error2>(on: newQueue) { newMachine, fulfill, _reject, configure in
            
            #if DEBUG
                configure.isChained = true
            #endif
            
            let selfMachine = self._machine
            
            self._then(on: newQueue, &localCanceller) {
                if let value = selfMachine.value.rawValue {
                    fulfill(value)
                }
                else if let errorInfo = selfMachine.errorInfo.rawValue {
                    let innerTask = failureClosure(errorInfo)
                    _bindInnerTask(innerTask, newMachine, fulfill, _reject, configure)
                }
            }
            
        }.name("\(self.name)-failure")
    }
    
    // MARK: - finally

    @discardableResult
    public func finally<V2, E2>(on queue: SwiftTaskQueue = .current, _ closure: @escaping () -> Task<V2, E2>) -> Task<Value, Error> {
        var dummyCanceller: Canceller? = nil
        return self.finally(on: queue, &dummyCanceller, closure)
    }

    @discardableResult
    public func finally<C: Canceller, V2, E2>(on queue: SwiftTaskQueue = .current, _ canceller: inout C?, _ closure: @escaping () -> Task<V2, E2>) -> Task<Value, Error> {

        var localCanceller = canceller; defer { canceller = localCanceller }
        var dummyCanceller: Canceller? = nil
        let newQueue = queue == .current ? _machine.queue : queue
        return Task<Value, Error>(on: newQueue) { newMachine, fulfill, _reject, configure in

            #if DEBUG
            configure.isChained = true
            #endif

            let selfMachine = self._machine

            // NOTE: using `self._then()` + `selfMachine` instead of `self.then()` will reduce Task allocation
            self._then(on: newQueue, &localCanceller) {
                closure()._then(on: .current, &dummyCanceller) {
                    if let value = selfMachine.value.rawValue {
                        fulfill(value)
                    } else if let errorInfo = selfMachine.errorInfo.rawValue {
                        _reject(errorInfo)
                    } else {
                        fatalError("unknown state")
                    }
                }
            }

        }.name("\(self.name)-finally")
    }

    @discardableResult
    public func finally(on queue: SwiftTaskQueue = .current, _ closure: @escaping () -> Void) -> Task<Value, Error> {
        var dummyCanceller: Canceller? = nil
        return self.finally(on: queue, &dummyCanceller, closure)
    }

    @discardableResult
    public func finally<C: Canceller>(on queue: SwiftTaskQueue = .current, _ canceller: inout C?, _ closure: @escaping () -> Void) -> Task<Value, Error> {

        self._then(on: queue, &canceller) {
            closure()
        }

        return self.name("\(self.name)-finally")
    }
    
    // MARK: - on
    
    ///
    /// Add side-effects after completion.
    ///
    /// - Note: This method doesn't create new task, so it has better performance over `then()`/`success()`/`failure()`.
    /// - Returns: Self (same `Task`)
    ///
    @discardableResult public func on(success: ((Value) -> Void)? = nil, failure: ((ErrorInfo) -> Void)? = nil) -> Self
    {
        var dummyCanceller: Canceller? = nil
        return self.on(&dummyCanceller, success: success, failure: failure)
    }
    
    public func on<C: Canceller>(_ canceller: inout C?, success: ((Value) -> Void)? = nil, failure: ((ErrorInfo) -> Void)? = nil) -> Self
    {
        let selfMachine = self._machine
        
        self._then(on: selfMachine.queue, &canceller) {
            if let value = selfMachine.value.rawValue {
                success?(value)
            }
            else if let errorInfo = selfMachine.errorInfo.rawValue {
                failure?(errorInfo)
            }
        }
        
        return self
    }
    
    /// Pause task.
    @discardableResult public func pause() -> Bool
    {
        return self._machine.handlePause()
    }
    
    /// Resume task.
    @discardableResult public func resume() -> Bool
    {
        return self._machine.handleResume()
    }
    
    /// Cancel task.
    @discardableResult public func cancel(error: Error? = nil) -> Bool
    {
        return self._machine.handleCancel(error)
    }
    
}

// MARK: - Helper

internal func _bindInnerTask<Value2, Error, Error2>(
    _ innerTask: Task<Value2, Error2>,
    _ newMachine: _StateMachine<Value2, Error>,
    _ fulfill: @escaping Task<Value2, Error>.FulfillHandler,
    _ _reject: @escaping Task<Value2, Error>._RejectInfoHandler,
    _ configure: TaskConfiguration
    )
{
    switch innerTask.state {
        case .Fulfilled:
            fulfill(innerTask.value!)
            return
        case .Rejected, .Cancelled:
            let (error2, isCancelled) = innerTask.errorInfo!
            
            // NOTE: innerTask's `error2` will be treated as `nil` if not same type as outerTask's `Error` type
            _reject((error2 as? Error, isCancelled))
            return
        default:
            break
    }
    
    innerTask.then(on: newMachine.queue) { (value: Value2?, errorInfo2: Task<Value2, Error2>.ErrorInfo?) -> Void in
        if let value = value {
            fulfill(value)
        }
        else if let errorInfo2 = errorInfo2 {
            let (error2, isCancelled) = errorInfo2
            
            // NOTE: innerTask's `error2` will be treated as `nil` if not same type as outerTask's `Error` type
            _reject((error2 as? Error, isCancelled))
        }
    }
    
    configure.pause = { innerTask.pause(); return }
    configure.resume = { innerTask.resume(); return }
    configure.cancel = { innerTask.cancel(); return }
    
    // pause/cancel innerTask if descendant task is already paused/cancelled
    if newMachine.state.rawValue == .Paused {
        innerTask.pause()
    }
    else if newMachine.state.rawValue == .Cancelled {
        innerTask.cancel()
    }
}

// MARK: - all

/// Task.all global function (Variadic Parameters)
public func all<V, E>(_ tasks: Task<V, E>..., concurrency: UInt = UInt.max) -> Task<[V], E> {
    return Task<V, E>.all(tasks, concurrency: concurrency)
}

/// Task.all global function (Sequence)
public func all<V, E, S: Sequence>(_ tasks: S, concurrency: UInt = UInt.max) -> Task<[V], E> where S.Iterator.Element == Task<V, E> {
    return Task<V, E>.all(tasks, concurrency: concurrency)
}

extension Task
{
    public class func all<S: Sequence>(_ tasks: S, concurrency: UInt = UInt.max) -> Task<[Value], Error> where S.Iterator.Element == Task<Value, Error>
    {
        let tasks = Array(tasks)
        guard !tasks.isEmpty else {
            return Task<[Value], Error>(value: [])
        }

        return Task<[Value], Error> { machine, fulfill, _reject, configure in
            
            var completedCount = 0
            let totalCount = tasks.count
            let lock = _RecursiveLock()
            let cancelled = _Atomic(false)
            var resumedCount = 0
            
            for task in tasks {
                task.success { (value: Value) -> Void in
                    
                    lock.lock()
                    completedCount += 1
                    
                    if completedCount == totalCount {
                        var values: [Value] = Array()
                        
                        for task in tasks {
                            values.append(task.value!)
                        }
                        
                        fulfill(values)
                    } else {
                        let pausedTask = tasks.first(where: { $0.state == .Paused })
                        pausedTask?.resume()
                    }
                    
                    lock.unlock()
                    
                }.failure { (errorInfo: ErrorInfo) -> Void in

                    let changed = cancelled.updateIf { $0 == false ? true : nil }
                    if changed != nil {
                        lock.lock()
                        _reject(errorInfo)

                        for task in tasks {
                            task.cancel()
                        }
                        lock.unlock()
                    }
                }
                if resumedCount < concurrency {
                    task.resume()
                    resumedCount += 1
                }
            }
            
            configure.pause = { self.pauseAll(tasks); return }
            configure.resume = { self.resumeAll(tasks); return }
            configure.cancel = {
                if !cancelled.rawValue {
                    self.cancelAll(tasks);
                }
            }
            
        }.name("Task.all")
    }
    
    public class func cancelAll(_ tasks: [Task])
    {
        for task in tasks {
            task.cancel()
        }
    }
    
    public class func pauseAll(_ tasks: [Task])
    {
        for task in tasks {
            task.pause()
        }
    }
    
    public class func resumeAll(_ tasks: [Task])
    {
        for task in tasks {
            task.resume()
        }
    }
}

// MARK: - race

public func race<V, E>(_ tasks: Task<V, E>...) -> Task<V, E> {
    return race(tasks)
}

public func race<V, E>(_ tasks: [Task<V, E>]) -> Task<V, E> {
    precondition(!tasks.isEmpty, "`Task.race(tasks)` with empty `tasks` should not be called. It will never be fulfilled or rejected.")
    
    return Task<V, E> { machine, fulfill, _reject, configure in
        
        var completedCount = 0
        let lock = _RecursiveLock()
        
        for task in tasks {
            task.on(success: { (value) in
                lock.lock()
                completedCount += 1
                
                if completedCount == 1 {
                    fulfill(value)
                    Task.cancelAll(tasks)
                }
                lock.unlock()
            }, failure: { (error, isCancelled) in
                lock.lock()
                completedCount += 1
                
                if completedCount == 1 {
                    let errorInfo = Task<V, E>.ErrorInfo(error: error, isCancelled: isCancelled)
                    _reject(errorInfo)
                }
                lock.unlock()
            })
        }
        
        configure.pause = { Task.pauseAll(tasks) }
        configure.resume = { Task.resumeAll(tasks) }
        configure.cancel = { Task.cancelAll(tasks) }
        
    }.name("Task.race")
}

// MARK: - allSettled

public struct Settled<V, E> {
    let state: TaskState
    let value: V?
    let errorInfo: Task<V, E>.ErrorInfo?
}

public func allSettled<V, E>(_ tasks: Task<V, E>...) -> Task<[Settled<V, E>], E> {
    return allSettled(tasks)
}

public func allSettled<V, E, S: Sequence>(_ tasks: S) -> Task<[Settled<V, E>], E> where S.Iterator.Element == Task<V, E> {
    return all(tasks.map { $0.settled }).success { (_) -> Task<[Settled<V, E>], E> in
        return Task<[Settled<V, E>], E>(value: tasks.map { (task) -> Settled<V, E> in
            Settled<V, E>(state: task.state, value: task.value, errorInfo: task.errorInfo)
        })
    }
}

// MARK: - zip

// 2
public func zip<A, B, E>(_ a: Task<A, E>, _ b: Task<B, E>) -> Task<(A, B), E> {
    return all(a.voidTask, b.voidTask).success { (_) -> Task<(A, B), E> in
        return Task<(A, B), E>(value: (a.value!, b.value!))
    }
}
// 3
public func zip<A, B, C, E>(_ a: Task<A, E>, _ b: Task<B, E>, _ c: Task<C, E>) -> Task<(A, B, C), E> {
    return all(a.voidTask, b.voidTask, c.voidTask).success { (_) -> Task<(A, B, C), E> in
        return Task<(A, B, C), E>(value: (a.value!, b.value!, c.value!))
    }
}
// 4
public func zip<A, B, C, D, E>(_ a: Task<A, E>, _ b: Task<B, E>, _ c: Task<C, E>, _ d: Task<D, E>) -> Task<(A, B, C, D), E> {
    return all(a.voidTask, b.voidTask, c.voidTask, d.voidTask).success { (_) -> Task<(A, B, C, D), E> in
        return Task<(A, B, C, D), E>(value: (a.value!, b.value!, c.value!, d.value!))
    }
}

