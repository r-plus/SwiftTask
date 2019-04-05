//
//  _InterruptableTask.swift
//  SwiftTask
//
//  Created by Yasuhiro Inami on 2014/12/25.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import SwiftTask
//import Async
typealias _InterruptableTask = Task<String, String>

/// 1. Invokes `progressCount/2` progresses at t=0.2
/// 2. Checks cancel & pause at t=0.4
/// 3. Invokes remaining `progressCount-progressCount/2` progresses at t=0.4~ (if not paused)
/// 4. Either fulfills with "OK" or rejects with "ERROR" at t=0.4~ (if not paused)
func _interruptableTask(progressCount: Int, finalState: TaskState = .fulfilled) -> _InterruptableTask
{
    return _InterruptableTask { fulfill, reject, configure in
        
        // NOTE: not a good flag, watch out for race condition!
        var isCancelled = false
        var isPaused = false
        
        // 1st delay (t=0.2)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.2) {
//        Async.background(after: 0.2) {
        
            // 2nd delay (t=0.4)
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.2) {
//            Async.background(after: 0.2) {
            
                // NOTE: no need to call reject() because it's already rejected (cancelled) internally
                if isCancelled { return }
                
                while isPaused {
                    print("pausing...")
                    Thread.sleep(forTimeInterval: 0.1)
                }
                
                DispatchQueue.main.async {
                    if finalState == .fulfilled {
                        fulfill("OK")
                    }
                    else {
                        reject("ERROR")
                    }
                }
            }
        }
        
        configure.pause = {
            isPaused = true;
            return
        }
        configure.resume = {
            isPaused = false;
            return
        }
        configure.cancel = {
            isCancelled = true;
            return
        }
        
    }
}
