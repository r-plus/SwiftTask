//
//  SwiftTaskTests.swift
//  SwiftTaskTests
//
//  Created by Yasuhiro Inami on 2014/08/21.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

@testable import SwiftTask
import Async
import XCTest

/// Safe background flag checking delay to not conflict with main-dispatch_after.
/// (0.3 may be still short for certain environment)
let SAFE_BG_FLAG_CHECK_DELAY = 0.5

class AsyncSwiftTaskTests: SwiftTaskTests
{
    override var isAsync: Bool { return true }
}

class SwiftTaskTests: _TestCase
{
    //--------------------------------------------------
    // MARK: - Init
    //--------------------------------------------------
    
    func testInit_value()
    {
        // NOTE: this is non-async test
        if self.isAsync { return }
        
        Task<String, ErrorString>(value: "OK").success { value -> Void in
            XCTAssertEqual(value, "OK")
        }
    }
    
    func testInit_error()
    {
        // NOTE: this is non-async test
        if self.isAsync { return }
        
        Task<String, ErrorString>(error: "ERROR").failure { error, isCancelled -> String in
            
            XCTAssertEqual(error!, "ERROR")
            return "RECOVERY"
            
        }
    }
    
    func testInit_dispatch() {
        if !self.isAsync { return }
        let expect = self.expectation(description: #function)
        
        XCTAssertTrue(Thread.isMainThread)
        DispatchQueue.global(qos: .utility).async {
            Task<String, ErrorString> { fulfill, reject, _ in
                XCTAssertTrue(!Thread.isMainThread)
                XCTAssertTrue(Thread.current.qualityOfService == .utility)
                fulfill("OK")
            }.success { value -> Void in
                // keep prev. thread if not specified.
                XCTAssertTrue(!Thread.isMainThread)
                XCTAssertTrue(Thread.current.qualityOfService == .utility)
                XCTAssertEqual(value, "OK")
            }.success { _ -> Task<Void, ErrorString> in
                // thread changeable
                XCTAssertTrue(!Thread.isMainThread)
                XCTAssertTrue(Thread.current.qualityOfService == .utility)
                return Task<String, ErrorString>(value: "OK2").success { (_) -> Void in
                    XCTAssertTrue(!Thread.isMainThread)
                    XCTAssertTrue(Thread.current.qualityOfService == .utility)
                }
            }.success { (_) -> Void in
                XCTAssertTrue(!Thread.isMainThread)
                XCTAssertTrue(Thread.current.qualityOfService == .utility)
                expect.fulfill()
            }
        }
        self.wait()
    }
    
    func testInit_on_queue() {
        if !self.isAsync { return }
        let expect = self.expectation(description: #function)
        
        DispatchQueue.global(qos: .utility).async {
            Task<String, ErrorString>(on: .main) { fulfill, reject, _ in
                XCTAssertTrue(Thread.isMainThread)
                fulfill("OK")
            }.success { value -> Void in
                // keep prev. thread if not specified.
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(value, "OK")
            }.success(on: .background) { _ -> Task<Void, ErrorString> in
                // thread changeable
                XCTAssertTrue(!Thread.isMainThread)
                XCTAssertTrue(Thread.current.qualityOfService == .background)
                return Task<String, ErrorString>(value: "OK2").success(on: .main) { (_) -> Void in
                    XCTAssertTrue(Thread.isMainThread)
                }
            }.success { (_) -> Void in
                // keep prev(not keep inner task) thread (background!) if not specified.
                XCTAssertTrue(!Thread.isMainThread)
                XCTAssertTrue(Thread.current.qualityOfService == .background)
                expect.fulfill()
            }
        }
        self.wait()
    }
    
    //--------------------------------------------------
    // MARK: - Fulfill
    //--------------------------------------------------
    
    func testFulfill_success()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
            
        }.success { value -> Void in
                
            XCTAssertEqual(value, "OK")
            expect.fulfill()
                
        }
        
        self.wait()
    }
    
    func testFulfill_success_failure()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
         
        }.success { value -> Void in
            
            XCTAssertEqual(value, "OK")
            expect.fulfill()
            
        }.failure { error, isCancelled -> Void in
            
            XCTFail("Should never reach here.")
            
        }
        
        self.wait()
    }
    
    func testFulfill_failure_success()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
            
        }.failure { error, isCancelled -> String in
            
            XCTFail("Should never reach here.")
            
            return "RECOVERY"
            
        }.success { value -> Void in
            
            XCTAssertEqual(value, "OK", "value should be derived from 1st task, passing through 2nd failure task.")
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    func testFulfill_success_innerTask_fulfill()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
            
        }.success { value -> Task<String, ErrorString> in
            
            XCTAssertEqual(value, "OK")
            
            return Task<String, ErrorString> { fulfill, reject, configure in
                
                self.perform {
                    fulfill("OK2")
                }
                
            }
            
        }.success { value -> Void in
            
            XCTAssertEqual(value, "OK2")
            
            expect.fulfill()
        }
        
        self.wait()
    }
    
    func testFulfill_success_innerTask_reject()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
            
        }.success { value -> Task<String, ErrorString> in
            
            XCTAssertEqual(value, "OK")
            
            return Task<String, ErrorString> { fulfill, reject, configure in
                
                self.perform {
                    reject("ERROR")
                }
                
            }
            
        }.success { value -> Void in
            
            XCTFail("Should never reach here.")
            
        }.failure { error, isCancelled -> Void in
            
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    func testFulfill_then()
    {
        typealias Task = SwiftTask.Task<String, ErrorString>
        
        let expect = self.expectation(description: #function)
        
        Task { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
            
        }.then(on: .current) { value, errorInfo -> String in
            // thenClosure can handle both fulfilled & rejected
                
            XCTAssertEqual(value!, "OK")
            XCTAssertTrue(errorInfo == nil)
            return "OK2"
            
        }.then(on: .current) { value, errorInfo -> Void in
                
            XCTAssertEqual(value!, "OK2")
            XCTAssertTrue(errorInfo == nil)
            expect.fulfill()
                
        }
        
        self.wait()
    }
    
    //--------------------------------------------------
    // MARK: - Reject
    //--------------------------------------------------
    
    func testReject_failure()
    {
        let expect = self.expectation(description: #function)
        
        Task<Void, ErrorString> { fulfill, reject, configure in
            
            XCTAssertTrue(Thread.isMainThread)
            self.perform {
                reject("ERROR")
            }
            
        }.failure { error, isCancelled -> Void in
            
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    func testReject_failure_on_queue()
    {
        let expect = self.expectation(description: #function)
        
        Task<Void, ErrorString> { fulfill, reject, configure in
            XCTAssertTrue(Thread.isMainThread)
            self.perform {
                reject("ERROR")
            }
        }.failure(on: .background) { error, isCancelled -> Void in
            XCTAssertTrue(!Thread.isMainThread)
            XCTAssertTrue(Thread.current.qualityOfService == .background)
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            expect.fulfill()
        }
        self.wait()
    }
    
    func testReject_success_failure()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                reject("ERROR")
            }
            
        }.success { value -> Void in
            
            XCTFail("Should never reach here.")
                
        }.failure { error, isCancelled -> Void in
            
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    func testReject_failure_success()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                reject("ERROR")
            }
        
        }.failure { error, isCancelled -> String in
            
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            
            return "RECOVERY"
            
        }.success { value -> Void in
            
            XCTAssertEqual(value, "RECOVERY", "value should be derived from 2nd failure task.")
            
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    func testReject_failure_innerTask_fulfill()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                reject("ERROR")
            }
            
        }.failure { error, isCancelled -> Task<String, ErrorString> in
            
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            
            return Task<String, ErrorString> { fulfill, reject, configure in
                
                self.perform {
                    fulfill("RECOVERY")
                }
                
            }
            
        }.success { value -> Void in
            
            XCTAssertEqual(value, "RECOVERY")
            
            expect.fulfill()
        }
        
        self.wait()
    }
    
    func testReject_failure_innerTask_reject()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                reject("ERROR")
            }
            
        }.failure { error, isCancelled -> Task<String, ErrorString> in
            
            XCTAssertEqual(error!, "ERROR")
            XCTAssertFalse(isCancelled)
            
            return Task<String, ErrorString> { fulfill, reject, configure in
                
                self.perform {
                    reject("ERROR2")
                }
                
            }
            
        }.success { value -> Void in
            
            XCTFail("Should never reach here.")
            
        }.failure { error, isCancelled -> Void in
            
            XCTAssertEqual(error!, "ERROR2")
            XCTAssertFalse(isCancelled)
            
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    func testReject_then()
    {
        typealias Task = SwiftTask.Task<String, ErrorString>
        
        let expect = self.expectation(description: #function)
        
        Task { fulfill, reject, configure in
            
            self.perform {
                reject("ERROR")
            }
            
        }.then(on: .current) { value, errorInfo -> String in
            // thenClosure can handle both fulfilled & rejected
            
            XCTAssertTrue(value == nil)
            XCTAssertEqual(errorInfo!.error!, "ERROR")
            XCTAssertFalse(errorInfo!.isCancelled)
            
            return "OK"
            
        }.then(on: .current) { value, errorInfo -> Void in
            
            XCTAssertEqual(value!, "OK")
            XCTAssertTrue(errorInfo == nil)
            expect.fulfill()
                
        }
        
        self.wait()
    }
    
    // MARK: - Finally

    // Finally return Task
    func testFinally_Return_Task_success() {
        let expect = self.expectation(description: #function)
        var fin = false

        Task<String, ErrorString> { fulfill, reject, configure in
            self.perform {
                fulfill("OK")
            }
        }.finally(on: .background) { () -> Task<Int, String> in
            XCTAssertTrue(!Thread.isMainThread)
            XCTAssertTrue(Thread.current.qualityOfService == .background)
            return Task<Int, String> { fulfill, reject, _ in
                self.perform {
                    // task in finally result value/error will ignored but wait state will be finished.
                    fin = true
                    reject("ERR")
                }
            }
        }.success { (value) -> Void in
            XCTAssert(fin)
            XCTAssertEqual(value, "OK")
            expect.fulfill()
        }

        self.wait()
    }

    func testFinally_Return_Task_failure() {
        let expect = self.expectation(description: #function)
        var fin = false

        Task<String, ErrorString> { fulfill, reject, configure in
            self.perform {
                reject("NG")
            }
        }.success { value -> Void in
            XCTFail("Should never reach here.")
        }.finally { () -> Task<Int, String> in
            return Task<Int, String> { fulfill, reject, _ in
                self.perform {
                    // task in finally result value/error will ignored but wait state will be finished.
                    fin = true
                    fulfill(1)
                }
            }
        }.failure { error, isCancelled -> Void in
            XCTAssert(fin)
            XCTAssertEqual(error!, "NG")
            expect.fulfill()
        }

        self.wait()
    }

    // Finally return Void
    func testFinally_success() {
        let expect = self.expectation(description: #function)
        var fin = false

        Task<String, ErrorString> { fulfill, reject, configure in
            self.perform {
                fulfill("OK")
            }
        }.finally {
            fin = true
        }.success { (value) -> Void in
            XCTAssert(fin)
            expect.fulfill()
        }

        self.wait()
    }
    
    func testFinally_failure() {
        let expect = self.expectation(description: #function)
        var fin = false
        
        Task<String, ErrorString> { fulfill, reject, configure in
            self.perform {
                reject("NG")
            }
        }.success { value -> Void in
            XCTFail("Should never reach here.")
        }.finally {
            fin = true
        }.failure { error, isCancelled -> Void in
            XCTAssert(fin)
            XCTAssertEqual(error!, "NG")
            expect.fulfill()
        }
        
        self.wait()
    }

    //--------------------------------------------------
    // MARK: - On
    //--------------------------------------------------
    
    func testOn_success()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                fulfill("OK")
            }
            
        }.on(success: { value in
            
            XCTAssertEqual(value, "OK")
            expect.fulfill()
            
        }).on(failure: { error, isCancelled in
            XCTFail("Should never reach here.")
        })
        
        self.wait()
    }
    
    func testOn_failure()
    {
        let expect = self.expectation(description: #function)
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                reject("NG")
            }
            
            }.on(success: { value in
                
                XCTFail("Should never reach here.")
                
            }).on(failure: { error, isCancelled in
                
                XCTAssertEqual(error!, "NG")
                XCTAssertFalse(isCancelled)
                expect.fulfill()
                
            })
        
        self.wait()
    }

    //--------------------------------------------------
    // MARK: - Cancel
    //--------------------------------------------------
    
    func testCancelVoidTask()
    {
        let expect = self.expectation(description: #function)

        let task = Task<String, String> { (fulfill, reject, conf) in
            // 10s
            DispatchQueue.global().asyncAfter(deadline: .now() + 10.0) {
                fulfill("OK")
            }
        }

        let voidTask = task.voidTask
        
        let successFailureTask = voidTask.success { value -> Void in
            XCTFail("Should never reach here because of cancellation.")
        }.on { [unowned task] (error, isCancelled) in
            // upstream tasks also cancelled.
            XCTAssertEqual(task.state, TaskState.cancelled)

            expect.fulfill()
        }
        
        Async.main(after: 0.1) {
            
            // cancel duaring first task is Running.
            let result = voidTask.cancel(error: "I get bored.")
            
            XCTAssertEqual(result, true)
            // upstream and downstream tasks are Cancelled.
            XCTAssertEqual(task.state, TaskState.cancelled)
            XCTAssertEqual(voidTask.state, TaskState.cancelled)
            XCTAssertEqual(successFailureTask.state, TaskState.cancelled)
            
        }
        
        self.wait()
    }
    
    func testCancel()
    {
        let expect = self.expectation(description: #function)
//        var progressCount = 0
        
        let task = _interruptableTask()
        
//        task.progress { oldProgress, newProgress in
//
//            progressCount += 1
//
//            // 1 <= progressCount <= 3 (not 5)
//            XCTAssertGreaterThanOrEqual(progressCount, 1)
//            XCTAssertLessThanOrEqual(progressCount, 3, "progressCount should be stopped to 3 instead of 5 because of cancellation.")
//
        task.success { value -> Void in
            
            XCTFail("Should never reach here because of cancellation.")
            
        }.failure { error, isCancelled -> Void in
            
            XCTAssertEqual(error!, "I get bored.")
            XCTAssertTrue(isCancelled)
            
//            XCTAssertEqual(progressCount, 2, "progressCount should be stopped to 2 instead of 5 because of cancellation.")
            
            expect.fulfill()
                
        }
        
        // cancel at time between 1st & 2nd delay (t=0.3)
        Async.main(after: 0.3) {
            
            task.cancel(error: "I get bored.")
            
            XCTAssertEqual(task.state, TaskState.cancelled)

        }
        
        self.wait()
    }
    
    func testCancel_then_innerTask()
    {
        let expect = self.expectation(description: #function)
        
        let task1 = _interruptableTask()
        
        var task2: _InterruptableTask? = nil
        
        let task3 = task1.then(on: .current) { value, errorInfo -> _InterruptableTask in
            
            task2 = _interruptableTask()
            return task2!
            
        }
        
        task3.failure { error, isCancelled -> String in
            
            XCTAssertEqual(error!, "I get bored.")
            XCTAssertTrue(isCancelled)
            
            expect.fulfill()
            
            return "DUMMY"
        }
        
        // cancel task3 at time between task1 fulfilled & before task2 completed (t=0.7)
        Async.main(after: 0.7) {
            
            task3.cancel(error: "I get bored.")
            
            XCTAssertEqual(task3.state, TaskState.cancelled)
            
            XCTAssertTrue(task2 != nil, "task2 should be created.")
            XCTAssertEqual(task2!.state, TaskState.cancelled, "task2 should be cancelled because task2 is created and then task3 (wrapper) is cancelled.")
            
        }
        
        self.wait()
    }
    
    //--------------------------------------------------
    // MARK: - Pause & Resume
    //--------------------------------------------------
    
    func testPauseResume()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
//        var progressCount = 0
        
        let task = _interruptableTask()
        
//        task.progress { _ in
//
//            progressCount += 1
//            return
//
        task.success { value -> Void in
            
            XCTAssertEqual(value, "OK")
//            XCTAssertEqual(progressCount, 5)
            expect.fulfill()
            
        }
        
        // pause at t=0.25 (between _interruptableTask's 1st & 2nd delay before pause-check)
        Async.main(after: 0.25) {
            
            task.pause()
            
            XCTAssertEqual(task.state, TaskState.paused)

            // resume at t=0.75
            Async.main(after: 0.5) {
                
                XCTAssertEqual(task.state, TaskState.paused)

                task.resume()
                
                XCTAssertEqual(task.state, TaskState.running, "`task` should start running again.")
                
            }
        }
        
        self.wait()
    }
    
    func testPauseResume_innerTask()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        
        let task = _interruptableTask()
        weak var innerTask: _InterruptableTask?
        
        // chain async-task with `then`
        let task2 = task.then(on: .current) { (_, _) -> _InterruptableTask in
            innerTask = _interruptableTask()
            return innerTask!
        }
        
        task2.success { value -> Void in
            XCTAssertEqual(value, "OK")
            expect.fulfill()
        }
        
        // pause at t=0.3 (between _interruptableTask's 1st & 2nd delay before pause-check)
        Async.main(after: 0.3) {
            
            // NOTE: task2 will be paused,
            task2.pause()
            
            XCTAssertEqual(task2.state, TaskState.paused)

            XCTAssertNil(innerTask, "`innerTask` should NOT be created yet.")
            
            XCTAssertEqual(task.state, TaskState.running, "`task` should NOT be paused.")
            XCTAssertNil(task.value, "`task` should NOT be fulfilled yet.")
            
            // resume at t=0.7
            Async.main(after: 0.4) {
                
                XCTAssertEqual(task2.state, TaskState.paused)

                XCTAssertNotNil(innerTask, "`innerTask` should be created at this point.")
                XCTAssertEqual(innerTask!.state, task2.state, "`innerTask!.state` should be same as `task2.state`.")
                
                XCTAssertEqual(task.state, TaskState.fulfilled, "`task` should NOT be paused, and it should be fulfilled at this point.")
                XCTAssertEqual(task.value!, "OK", "`task` should be fulfilled.")
                
                task2.resume()
                
                XCTAssertEqual(task2.state, TaskState.running, "`task2` should be resumed.")
                
                // check tasks's states at t=0.7
                Async.main(after: 0.1) {
                    XCTAssertEqual(task2.state, TaskState.running)
                    XCTAssertEqual(innerTask!.state, task2.state, "`innerTask!.state` should be same as `task2.state`.")
                    XCTAssertEqual(task.state, TaskState.fulfilled)
                }
                
            }
        }
        
        self.wait()
    }
    
    //--------------------------------------------------
    // MARK: - Retry
    //--------------------------------------------------
    
    func testRetry_success()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 3
        let fulfilledTryCount = 2
        var actualTryCount = 0
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                
                actualTryCount += 1
                XCTAssertEqual(actualTryCount, configure.retryCount+1)
                
                if actualTryCount != fulfilledTryCount {
                    reject("ERROR \(actualTryCount)")
                }
                else {
                    fulfill("OK")
                }
            }
            
        }.retry(maxTryCount-1).failure { errorInfo -> String in
            
            XCTFail("Should never reach here because `task.retry(\(maxTryCount-1))` will be fulfilled at `fulfilledTryCount` try even though previous retries will be rejected.")
            
            return "DUMMY"
            
        }.success { value -> Void in
            
            XCTAssertEqual(value, "OK")
            expect.fulfill()
                
        }
        
        self.wait()
        
        XCTAssertEqual(actualTryCount, fulfilledTryCount, "`actualTryCount` should be stopped at `fulfilledTryCount`, not `maxTryCount`.")
    }
    
    func testRetry_success_on_queue()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 3
        let fulfilledTryCount = 2
        var actualTryCount = 0
        
        DispatchQueue.global(qos: .background).async {
            Task<String, ErrorString>(on: .utility) { fulfill, reject, configure in
                XCTAssertTrue(Thread.current.qualityOfService == .utility)
                print("qos: \(Thread.current.qualityOfService.rawValue) \(actualTryCount)")
                self.perform {
                    actualTryCount += 1
                    XCTAssertEqual(actualTryCount, configure.retryCount+1)
    
                    if actualTryCount != fulfilledTryCount {
                        reject("ERROR \(actualTryCount)")
                    }
                    else {
                        fulfill("OK")
                    }
                }
            }.retry(maxTryCount-1).failure(on: .main) { errorInfo -> String in
                XCTFail("Should never reach here because `task.retry(\(maxTryCount-1))` will be fulfilled at `fulfilledTryCount` try even though previous retries will be rejected.")
                return "DUMMY"
            }.success { value -> Void in
                // keep prev (failure method returned task) thread.
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(value, "OK")
                expect.fulfill()
            }
        }
        
        self.wait()
        
        XCTAssertEqual(actualTryCount, fulfilledTryCount, "`actualTryCount` should be stopped at `fulfilledTryCount`, not `maxTryCount`.")
    }
    
    func testRetry_failure()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 3
        var actualTryCount = 0
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                actualTryCount += 1
                XCTAssertEqual(actualTryCount, configure.retryCount+1)
                reject("ERROR \(actualTryCount)")
            }
            
        }.retry(maxTryCount-1).failure { error, isCancelled -> String in
            
            XCTAssertEqual(error!, "ERROR \(actualTryCount)")
            XCTAssertFalse(isCancelled)
            
            expect.fulfill()
            
            return "DUMMY"
            
        }
        
        self.wait()
        
        XCTAssertEqual(actualTryCount, maxTryCount, "`actualTryCount` should reach `maxTryCount` because task keeps rejected and never fulfilled.")
    }
    
    func testRetry_condition()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 4
        var actualTryCount = 0
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                actualTryCount += 1
                XCTAssertEqual(actualTryCount, configure.retryCount+1)
                reject("ERROR \(actualTryCount)")
            }
            
            }.retry(maxTryCount-1) { error, isCancelled -> Bool in
                XCTAssertNotEqual(error!, "ERROR 0", "Should not evaluate retry condition on first try. It is not retry.")
                return actualTryCount < 3
            }.failure { error, isCancelled -> String in
                
                XCTAssertEqual(error!, "ERROR 3")
                XCTAssertFalse(isCancelled)
                
                expect.fulfill()
                
                return "DUMMY"
                
        }
        
        self.wait()
        
        XCTAssertEqual(actualTryCount, 3)
    }
    
    func testRetry_progress()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 3
        var actualTryCount = 0
//        var progressCount = 0
        
        Task<String, ErrorString> { fulfill, reject, configure in
            
            self.perform {
                

                actualTryCount += 1
                XCTAssertEqual(actualTryCount, configure.retryCount+1)
                
                if actualTryCount < maxTryCount {
                    reject("ERROR \(actualTryCount)")
                }
                else {
                    fulfill("OK")
                }
            }
            
        }.retry(maxTryCount - 1)
//            .progress { _ in
//
//            progressCount += 1
//
//            // 1 <= progressCount <= maxTryCount
//            XCTAssertGreaterThanOrEqual(progressCount, 1)
//            XCTAssertLessThanOrEqual(progressCount, maxTryCount)
//
        .success { value -> Void in
            
            XCTAssertEqual(value, "OK")
            expect.fulfill()
                
        }
        
        self.wait()
        
//        XCTAssertEqual(progressCount, maxTryCount)
    }
    
    func testRetry_pauseResume()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 5
        var actualTryCount = 0
        
        let retryableTask = Task<String, ErrorString> { fulfill, reject, configure in
            
            actualTryCount += 1
            XCTAssertEqual(actualTryCount, configure.retryCount+1)
            print("trying \(actualTryCount)")
            
            var isPaused = false
            
            Async.background(after: 0.1) {
                while isPaused {
                    print("pausing...")
                    Thread.sleep(forTimeInterval: 0.1)
                }
                Async.main(after: 0.2) {
                    if actualTryCount < maxTryCount {
                        reject("ERROR \(actualTryCount)")
                    }
                    else {
                        fulfill("OK")
                    }
                }
            }
            
            configure.pause = {
                isPaused = true
                return
            }
            configure.resume = {
                isPaused = false
                return
            }
            
        }.retry(maxTryCount-1)
        
        retryableTask.success { value -> Void in

            XCTAssertEqual(value, "OK")
            expect.fulfill()
            
        }
        
        // pause `retryableTask` at some point before all tries completes
        Async.main(after: 0.5) {
            retryableTask.pause()
            return
        }

        Async.main(after: 1.5) {
            retryableTask.resume()
            return
        }
        
        self.wait(5)    // wait a little longer
        
        XCTAssertEqual(actualTryCount, maxTryCount)
    }
    
    func testRetry_cancel()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 3
        var actualTryCount = 0
        
        let task = Task<String, ErrorString> { fulfill, reject, configure in
            
            Async.main(after: 0.3) {
                
                actualTryCount += 1
                XCTAssertEqual(actualTryCount, configure.retryCount+1)
                
                if actualTryCount < maxTryCount {
                    reject("ERROR \(actualTryCount)")
                }
                else {
                    fulfill("OK")
                }
            }
            
            return
            
        }
            
        let retryableTask = task.retry(maxTryCount-1)
            
        retryableTask.success { value -> Void in
            
            XCTFail("Should never reach here because `retryableTask` is cancelled.")
                
        }.failure { errorInfo -> Void in
            
            XCTAssertTrue(errorInfo.isCancelled)
//            expect.fulfill()
            
        }
        
        task.success { value -> Void in
            
            XCTFail("Should never reach here because `retryableTask` is cancelled so original-`task` should also be cancelled.")
            
        }.failure { errorInfo -> Void in
            
            XCTAssertTrue(errorInfo.isCancelled)
            expect.fulfill()
                
        }
        
        // cancel `retryableTask` at some point before all tries completes
        Async.main(after: 0.2) {
            retryableTask.cancel()
            return
        }
        
        self.wait()
        
        XCTAssertTrue(actualTryCount < maxTryCount, "`actualTryCount` should not reach `maxTryCount` because of cancellation.")
    }
    
    func testRetry_PausedTask() {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        let expect = self.expectation(description: #function)
        let maxTryCount = 3
        var actualTryCount = 0
        
        let pausedRetryableTask = Task<String, ErrorString>(paused: true) { fulfill, reject, configure in
            
            Async.main(after: 0.3) {
                
                actualTryCount += 1
                XCTAssertEqual(actualTryCount, configure.retryCount+1)
                
                if actualTryCount < maxTryCount {
                    reject("ERROR \(actualTryCount)")
                }
                else {
                    fulfill("OK")
                }
            }
        }.retry(maxTryCount-1)

        // paused is first task, retry registered task is running.
        XCTAssertFalse(pausedRetryableTask._paused)
        
        pausedRetryableTask.on(success: { (value) -> Void in
            XCTAssertEqual(value, "OK")
            expect.fulfill()
        })
        // first, we must pause running retry() returned task to resume upstream first task.
        let pause = pausedRetryableTask.pause()
        XCTAssertTrue(pause)
        let resumed = pausedRetryableTask.resume()
        XCTAssertTrue(resumed)
        
        self.wait()
        
        XCTAssertEqual(actualTryCount, maxTryCount)
    }
    
    //--------------------------------------------------
    // MARK: - race
    //--------------------------------------------------

    func testRaceFailure() {
        let expect = self.expectation(description: #function)
        let t1 = Task<String, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                fulfill("1")
            }
        }
        let t2 = Task<String, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                reject(2)
            }
        }
        
        race(t1, t2).on(success: { _ in
            XCTFail()
        }, failure: { (e, _) in
            XCTAssertEqual(e, 2)
            expect.fulfill()
        })
        self.wait()
    }

    func testRaceSuccess() {
        let expect = self.expectation(description: #function)
        let t1 = Task<String, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                fulfill("1")
            }
        }
        let t2 = Task<String, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                reject(2)
            }
        }
        
        race(t1, t2).on(success: { v in
            XCTAssertEqual(v, "1")
            expect.fulfill()
        }, failure: { _, _ in
            XCTFail()
        })
        self.wait()
    }

    //--------------------------------------------------
    // MARK: - allSettled
    //--------------------------------------------------

    func testAllSettled() {
        let expect = self.expectation(description: #function)
        let t1 = Task<String, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                fulfill("1")
            }
        }
        let t2 = Task<String, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                reject(2)
            }
        }
        
        allSettled(t1, t2).success { (results) -> Void in
            XCTAssertEqual(results[0].state, .fulfilled)
            XCTAssertEqual(results[1].state, .rejected)
            XCTAssertEqual(results[0].value, "1")
            XCTAssertNil(results[1].value)
            XCTAssertNil(results[0].errorInfo)
            XCTAssertEqual(results[1].errorInfo?.error, 2)
            expect.fulfill()
        }
        self.wait()
    }
    
    //--------------------------------------------------
    // MARK: - Zip
    //--------------------------------------------------
    
    func testZip() {
        let expect = self.expectation(description: #function)
        let t1 = Task<String, Void> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                fulfill("1")
            }
        }
        let t2 = Task<Int, Void> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                fulfill(2)
            }
        }
        
        zip(t1, t2).success { (value1, value2) -> Void in
            XCTAssertEqual(value1, "1")
            XCTAssertEqual(value2, 2)
            expect.fulfill()
        }
        self.wait()
    }

    func testZip_Failure() {
        let expect = self.expectation(description: #function)
        let t1 = Task<String, Int> { fulfill, reject, conf in
            // 5s is longer than 3s(default timeout interval of self.wait())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                fulfill("1")
            }
        }
        let t2 = Task<Double, Int> { fulfill, reject, conf in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                reject(2)
            }
        }
        
        zip(t1, t2).success { (value1, value2) -> Void in
            XCTFail()
        }.failure { (error, _) -> Void in
            XCTAssertEqual(error, 2)
            XCTAssertEqual(t1.state, .running)
            expect.fulfill()
        }
        self.wait()
    }

    //--------------------------------------------------
    // MARK: - All
    //--------------------------------------------------
    
    func testAll_concurrency() {
        let expect = self.expectation(description: #function)
        let values = [1, 2, 3, 4]
        let waits = [4, 3, 2, 2]
        var r = [Int]()
        let serial = DispatchQueue(label: "lock")
        let tasks = zip(values, waits).map { arg -> Task<Int, Void> in
            let v = arg.0
            let w = Double(arg.1)
            return Task<Int, Void>(paused: true) { fulfill, reject, configure in
                DispatchQueue.global().asyncAfter(deadline: .now() + w) {
                    serial.sync {
                        r.append(v)
                    }
                    fulfill(v)
                }
            }
        }

        // 1: wait 4 -----> -----> -----> fulfill
        // 2: wait 3 -----> -----> fulfill
        // 3:                      wait: 2 -----> fulfill
        // 4:                             wait: 2 -----> fulfill
        all(tasks, concurrency: 2).success { (results) -> Void in
            XCTAssertEqual(results, values)
            XCTAssertEqual(r, [2, 1, 3, 4])
            expect.fulfill()
        }
        
        self.wait(7)
    }
    
    /// all fulfilled test
    func testAll_success()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        typealias Task = SwiftTask.Task<String, ErrorString>
        
        let expect = self.expectation(description: #function)
        var tasks: [Task] = Array()
        
        for i in 0..<10 {
            
            // define task
            let task = Task { fulfill, reject, configure in
                
                Async.background(after: 0.1) {
                    return
                }
                
                Async.background(after: 0.2) {
                    Async.main { fulfill("OK \(i)") }
                }
                
            }
            
            //
            // NOTE: 
            // For tracking each task's progress, you simply call `task.progress`
            // instead of `Task.all(tasks).progress`.
            //
//            task.progress { oldProgress, newProgress in
//                print("each progress = \(newProgress)")
//                return
//            }
            
            tasks.append(task)
        }
        
        all(tasks)
//            .progress { (oldProgress: Task.BulkProgress?, newProgress: Task.BulkProgress) in
//            
//            print("all progress = \(newProgress.completedCount) / \(newProgress.totalCount)")
//        
        .success { values -> Void in
            
            for i in 0..<values.count {
                XCTAssertEqual(values[i], "OK \(i)")
            }
            
            expect.fulfill()
            
        }
        
        self.wait()
    }
    
    /// any rejected test
    func testAll_failure()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        typealias Task = SwiftTask.Task<String, ErrorString>
        
        let expect = self.expectation(description: #function)
        var tasks: [Task] = Array()
        
        for i in 0..<5 {
            // define fulfilling task
            let task = Task { fulfill, reject, configure in
                Async.background(after: 0.1) {
                    Async.main { fulfill("OK \(i)") }
                    return
                }
                return
            }
            tasks.append(task)
        }
        
        for _ in 0..<5 {
            // define rejecting task
            let task = Task { fulfill, reject, configure in
                Async.background(after: 0.1) {
                    Async.main { reject("ERROR") }
                    return
                }
                return
            }
            tasks.append(task)
        }
        
        all(tasks).success { values -> Void in
            
            XCTFail("Should never reach here because of Task.all failure.")
            
        }.failure { error, isCancelled -> Void in
            
            XCTAssertEqual(error!, "ERROR", "Task.all non-cancelled error returns 1st-errored object (spec).")
            expect.fulfill()
            
        }
    
        self.wait()
    }
    
    func testAll_cancel()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        typealias Task = SwiftTask.Task<String, ErrorString>
        
        let expect = self.expectation(description: #function)
        var tasks: [Task] = Array()
        
        for i in 0..<10 {
            
            // define task
            let task = Task { fulfill, reject, configure in
                
                var isCancelled = false
                
                Async.background(after: 0.1) {
                    if isCancelled {
                        return
                    }
                    Async.main { fulfill("OK \(i)") }
                }
                
                configure.cancel = {
                    isCancelled = true
                    return
                }
                
            }
            
            tasks.append(task)
        }
        
        let groupedTask = all(tasks)
        
        groupedTask.success { values -> Void in
            
            XCTFail("Should never reach here.")
            
        }.failure { error, isCancelled -> Void in
            
            XCTAssertEqual(error!, "Cancel")
            XCTAssertTrue(isCancelled)
            expect.fulfill()
                
        }
        
        // cancel before fulfilled
        Async.main(after: 0.01) {
            groupedTask.cancel(error: "Cancel")
            return
        }
        
        self.wait()
    }
    
    func testAll_pauseResume()
    {
        // NOTE: this is async test
        if !self.isAsync { return }
        
        typealias Task = SwiftTask.Task<String, ErrorString>
        
        let expect = self.expectation(description: #function)
        var tasks: [Task] = Array()
        
        for i in 0..<10 {
            
            // define task
            let task = Task { fulfill, reject, configure in
                
                var isPaused = false
                
                Async.background(after: SAFE_BG_FLAG_CHECK_DELAY) {
                    while isPaused {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    Async.main { fulfill("OK \(i)") }
                }
                
                configure.pause = {
                    isPaused = true
                    return
                }
                configure.resume = {
                    isPaused = false
                    return
                }
                
            }
            
            tasks.append(task)
        }
        
        let groupedTask = all(tasks)
        
        groupedTask.success { values -> Void in
            
            for i in 0..<values.count {
                XCTAssertEqual(values[i], "OK \(i)")
            }
            
            expect.fulfill()
            
        }
        
        // pause & resume
        self.perform {
            
            groupedTask.pause()
            XCTAssertEqual(groupedTask.state, TaskState.paused)
            
            Async.main(after: 1.0) {
                
                groupedTask.resume()
                XCTAssertEqual(groupedTask.state, TaskState.running)
                
            }
        }
        
        self.wait()
    }
    
}
