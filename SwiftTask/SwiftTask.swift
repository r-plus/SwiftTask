//
//  SwiftTask.swift
//  SwiftTask
//
//  Created by Yasuhiro Inami on 2014/08/21.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

// Required for use in the playground Sources folder
import ObjectiveC

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

open class Task<Value, Error>: Cancellable, CustomStringConvertible
{
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
    internal let _weakified: Bool
    internal let _paused: Bool
    internal var _initClosure: _InitClosure!    // retained throughout task's lifetime
    
    public var state: TaskState { return self._machine.state.rawValue }
        
    /// fulfilled value
    public var value: Value? { return self._machine.value.rawValue }
    
    /// rejected/cancelled tuple info
    public var errorInfo: ErrorInfo? { return self._machine.errorInfo.rawValue }
    
    public var name: String = "DefaultTask"
    
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
    
    ///
    /// Create a new task.
    ///
    /// - e.g. Task<P, V, E>(weakified: false, paused: false) { progress, fulfill, reject, configure in ... }
    ///
    /// - Parameter weakified: Weakifies progress/fulfill/reject handlers to let player (inner asynchronous implementation inside `initClosure`) NOT CAPTURE this created new task. Normally, `weakified = false` should be set to gain "player -> task" retaining, so that task will be automatically deinited when player is deinited. If `weakified = true`, task must be manually retained somewhere else, or it will be immediately deinited.
    ///
    /// - Parameter paused: Flag to invoke `initClosure` immediately or not. If `paused = true`, task's initial state will be `.Paused` and needs to `resume()` in order to start `.Running`. If `paused = false`, `initClosure` will be invoked immediately.
    ///
    /// - Parameter initClosure: e.g. { progress, fulfill, reject, configure in ... }. `fulfill(value)` and `reject(error)` handlers must be called inside this closure, where calling `progress(progressValue)` handler is optional. Also as options, `configure.pause`/`configure.resume`/`configure.cancel` closures can be set to gain control from outside e.g. `task.pause()`/`task.resume()`/`task.cancel()`. When using `configure`, make sure to use weak modifier when appropriate to avoid "task -> player" retaining which often causes retain cycle.
    ///
    /// - Returns: New task.
    ///
    public init(weakified: Bool, paused: Bool, initClosure: @escaping InitClosure)
    {
        self._weakified = weakified
        self._paused = paused
        self._machine = _Machine(weakified: weakified, paused: paused)
        
        let _initClosure: _InitClosure = { _, fulfill, _reject, configure in
            // NOTE: don't expose rejectHandler with ErrorInfo (isCancelled) for public init
            initClosure(fulfill, { error in _reject(ErrorInfo(error: Optional(error), isCancelled: false)) }, configure)
        }
        
        self.setup(weakified: weakified, paused: paused, _initClosure: _initClosure)
    }
    
    ///
    /// Create a new task without weakifying progress/fulfill/reject handlers
    ///
    /// - e.g. Task<P, V, E>(paused: false) { progress, fulfill, reject, configure in ... }
    ///
    public convenience init(paused: Bool, initClosure: @escaping InitClosure)
    {
        self.init(weakified: false, paused: paused, initClosure: initClosure)
    }
    
    ///
    /// Create a new task without weakifying progress/fulfill/reject handlers (non-paused)
    ///
    /// - e.g. Task<P, V, E> { progress, fulfill, reject, configure in ... }
    ///
    public convenience init(initClosure: @escaping InitClosure)
    {
        self.init(weakified: false, paused: false, initClosure: initClosure)
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
    
    ///
    /// Create promise-like task which only allows fulfill & reject (no progress & configure)
    ///
    /// - e.g. Task<Any, Value, Error> { fulfill, reject in ... }
    ///
    public convenience init(promiseInitClosure: @escaping PromiseInitClosure)
    {
        self.init(initClosure: { fulfill, reject, configure in
            promiseInitClosure(fulfill, { error in reject(error) })
        })
    }
    
    /// internal-init for accessing `machine` inside `_initClosure`
    /// (NOTE: _initClosure has _RejectInfoHandler as argument)
    internal init(weakified: Bool = false, paused: Bool = false, _initClosure: @escaping _InitClosure)
    {
        self._weakified = weakified
        self._paused = paused
        self._machine = _Machine(weakified: weakified, paused: paused)
        
        self.setup(weakified: weakified, paused: paused, _initClosure: _initClosure)
    }
    
    // NOTE: don't use `internal init` for this setup method, or this will be a designated initializer
    internal func setup(weakified: Bool, paused: Bool, _initClosure: @escaping _InitClosure)
    {
//        #if DEBUG
//            let addr = String(format: "%p", unsafeAddressOf(self))
//            NSLog("[init] \(self.name) \(addr)")
//        #endif
        
        self._initClosure = _initClosure
        
        // will be invoked on 1st resume (only once)
        self._machine.initResumeClosure.rawValue = { [weak self] in
            
            // strongify `self` on 1st resume
            if let self_ = self {
                
                var fulfillHandler: FulfillHandler
                var rejectInfoHandler: _RejectInfoHandler
                
                if weakified {
                    //
                    // NOTE:
                    // When `weakified = true`,
                    // each handler will NOT capture `self_` (strongSelf on 1st resume)
                    // so it will immediately deinit if not retained in somewhere else.
                    //
                    fulfillHandler = { [weak self_] (value: Value) in
                        if let self_ = self_ {
                            self_._machine.handleFulfill(value)
                        }
                    }
                    
                    rejectInfoHandler = { [weak self_] (errorInfo: ErrorInfo) in
                        if let self_ = self_ {
                            self_._machine.handleRejectInfo(errorInfo)
                        }
                    }
                }
                else {
                    //
                    // NOTE:
                    // When `weakified = false`,
                    // each handler will capture `self_` (strongSelf on 1st resume)
                    // so that it will live until fulfilled/rejected.
                    //
                    fulfillHandler = { (value: Value) in
                        self_._machine.handleFulfill(value)
                    }
                    
                    rejectInfoHandler = { (errorInfo: ErrorInfo) in
                        self_._machine.handleRejectInfo(errorInfo)
                    }
                }
                
                _initClosure(self_._machine, fulfillHandler, rejectInfoHandler, self_._machine.configuration)
                
            }
        
        }
        
        if !paused {
            self.resume()
        }
    }
    
    deinit
    {
//        #if DEBUG
//            let addr = String(format: "%p", unsafeAddressOf(self))
//            NSLog("[deinit] \(self.name) \(addr)")
//        #endif
        
        // cancel in case machine is still running
        self.cancel(error: nil)
    }
    
    /// Sets task name (method chainable)
    public func name(_ name: String) -> Self
    {
        self.name = name
        return self
    }
    
    /// Creates cloned task.
    public func clone() -> Task
    {
        let clonedTask = Task(weakified: self._weakified, paused: self._paused, _initClosure: self._initClosure)
        clonedTask.name = "\(self.name)-clone"
        return clonedTask
    }
    
    private func pausedClone() -> Task {
        let clonedTask = Task(weakified: self._weakified, paused: true, _initClosure: self._initClosure)
        clonedTask.name = "\(self.name)-clone"
        return clonedTask
    }
    
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
    
    ///
    /// `then` (fulfilled & rejected) + closure returning **value**.
    /// (similar to `map` in functional programming)
    ///
    /// - e.g. task.then { value, errorInfo -> NextValueType in ... }
    ///
    /// - Returns: New `Task`
    ///
    @discardableResult func then<Value2>(_ thenClosure: @escaping (Value?, ErrorInfo?) -> Value2) -> Task<Value2, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.then(&dummyCanceller, thenClosure)
    }
    
    func then<Value2, C: Canceller>(_ canceller: inout C?, _ thenClosure: @escaping (Value?, ErrorInfo?) -> Value2) -> Task<Value2, Error>
    {
        return self.then(&canceller) { (value, errorInfo) -> Task<Value2, Error> in
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
    func then<Value2, Error2>(_ thenClosure: @escaping (Value?, ErrorInfo?) -> Task<Value2, Error2>) -> Task<Value2, Error2>
    {
        var dummyCanceller: Canceller? = nil
        return self.then(&dummyCanceller, thenClosure)
    }
    
    //
    // NOTE: then-canceller is a shorthand of `task.cancel(nil)`, i.e. these two are the same:
    //
    // - `let canceller = Canceller(); task1.then(&canceller) {...}; canceller.cancel();`
    // - `let task2 = task1.then {...}; task2.cancel();`
    //
    /// - Returns: New `Task`
    ///
    func then<Value2, Error2, C: Canceller>(_ canceller: inout C?, _ thenClosure: @escaping (Value?, ErrorInfo?) -> Task<Value2, Error2>) -> Task<Value2, Error2>
    {
        return Task<Value2, Error2> { [unowned self, weak canceller] newMachine, fulfill, _reject, configure in
            
            //
            // NOTE: 
            // We split `self` (Task) and `self.machine` (StateMachine) separately to
            // let `completionHandler` retain `selfMachine` instead of `self`
            // so that `selfMachine`'s `completionHandlers` can be invoked even though `self` is deinited.
            // This is especially important for ReactKit's `deinitSignal` behavior.
            //
            let selfMachine = self._machine
            
            self._then(&canceller) {
                let innerTask = thenClosure(selfMachine.value.rawValue, selfMachine.errorInfo.rawValue)
                _bindInnerTask(innerTask, newMachine, fulfill, _reject, configure)
            }
            
        }.name("\(self.name)-then")
    }

    /// invokes `completionHandler` "now" or "in the future"
    private func _then<C: Canceller>(_ canceller: inout C?, _ completionHandler: @escaping () -> Void)
    {
        switch self.state {
            case .Fulfilled, .Rejected, .Cancelled:
                completionHandler()
            default:
                var token: _HandlerToken? = nil
                self._machine.addCompletionHandler(&token, completionHandler)
            
                canceller = C { [weak self] in
                    self?._machine.removeCompletionHandler(token)
                }
        }
    }
    
    ///
    /// `success` (fulfilled) + closure returning **value**.
    /// (synonym for `map` in functional programming)
    ///
    /// - e.g. task.success { value -> NextValueType in ... }
    ///
    /// - Returns: New `Task`
    ///
    @discardableResult public func success<Value2>(_ successClosure: @escaping (Value) -> Value2) -> Task<Value2, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.success(&dummyCanceller, successClosure)
    }
    
    public func success<Value2, C: Canceller>(_ canceller: inout C?, _ successClosure: @escaping (Value) -> Value2) -> Task<Value2, Error>
    {
        return self.success(&canceller) { (value: Value) -> Task<Value2, Error> in
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
    public func success<Value2, Error2>(_ successClosure: @escaping (Value) -> Task<Value2, Error2>) -> Task<Value2, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.success(&dummyCanceller, successClosure)
    }
    
    public func success<Value2, Error2, C: Canceller>(_ canceller: inout C?, _ successClosure: @escaping (Value) -> Task<Value2, Error2>) -> Task<Value2, Error>
    {
        var localCanceller = canceller; defer { canceller = localCanceller }
        return Task<Value2, Error> { [unowned self] newMachine, fulfill, _reject, configure in
            
            #if DEBUG
                configure.isChained = true
            #endif
            
            let selfMachine = self._machine
            
            // NOTE: using `self._then()` + `selfMachine` instead of `self.then()` will reduce Task allocation
            self._then(&localCanceller) {
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
    
    ///
    /// `failure` (rejected or cancelled) + closure returning **value**.
    /// (synonym for `mapError` in functional programming)
    ///
    /// - e.g. task.failure { errorInfo -> NextValueType in ... }
    /// - e.g. task.failure { error, isCancelled -> NextValueType in ... }
    ///
    /// - Returns: New `Task`
    ///
    @discardableResult public func failure(_ failureClosure: @escaping (ErrorInfo) -> Value) -> Task
    {
        var dummyCanceller: Canceller? = nil
        return self.failure(&dummyCanceller, failureClosure)
    }
    
    public func failure<C: Canceller>(_ canceller: inout C?, _ failureClosure: @escaping (ErrorInfo) -> Value) -> Task
    {
        return self.failure(&canceller) { (errorInfo: ErrorInfo) -> Task in
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
    public func failure<Error2>(_ failureClosure: @escaping (ErrorInfo) -> Task<Value, Error2>) -> Task<Value, Error2>
    {
        var dummyCanceller: Canceller? = nil
        return self.failure(&dummyCanceller, failureClosure)
    }
    
    public func failure<Error2, C: Canceller>(_ canceller: inout C?, _ failureClosure: @escaping (ErrorInfo) -> Task<Value, Error2>) -> Task<Value, Error2>
    {
        var localCanceller = canceller; defer { canceller = localCanceller }
        return Task<Value, Error2> { [unowned self] newMachine, fulfill, _reject, configure in
            
            #if DEBUG
                configure.isChained = true
            #endif
            
            let selfMachine = self._machine
            
            self._then(&localCanceller) {
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
    public func finally(_ closure: @escaping () -> Void) -> Task<Value, Error>
    {
        var dummyCanceller: Canceller? = nil
        return self.finally(&dummyCanceller, closure)
    }
    
    public func finally<C: Canceller>(_ canceller: inout C?, _ closure: @escaping () -> Void) -> Task<Value, Error> {
        
        self._then(&canceller) {
            closure()
        }
        
        return self.name("\(self.name)-finally")
    }
    
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
        
        self._then(&canceller) {
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
    
    innerTask.then { (value: Value2?, errorInfo2: Task<Value2, Error2>.ErrorInfo?) -> Void in
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

// MARK: - Multiple Tasks

extension Task
{
    public class func all(_ tasks: [Task], concurrency: UInt = UInt.max) -> Task<[Value], Error>
    {
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
