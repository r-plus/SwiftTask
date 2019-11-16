//
//  _InterruptableTask.swift
//  SwiftTask
//
//  Created by Yasuhiro Inami on 2014/12/25.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

import SwiftTask
typealias _InterruptableTask = Task<String, String>

func _interruptableTask(finalState: TaskState = .fulfilled) -> _InterruptableTask
{
    return _InterruptableTask { fulfill, reject, configure in
        
        // NOTE: not a good flag, watch out for race condition!
        var isCancelled = false
        var isPaused = false
        
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.5) {

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
