//
//  TypeInferenceTests.swift
//  SwiftTask
//
//  Created by Yasuhiro Inami on 2014/11/20.
//  Copyright (c) 2014年 Yasuhiro Inami. All rights reserved.
//

@testable import SwiftTask
import XCTest

class TypeInferenceTests: _TestCase
{
    func testTypeInference()
    {
        Task<String, ErrorString> { fulfill, reject, configure in
            fulfill("OK")
        }.success { value -> [String] in    // NOTE: although explicitly adding closure-returning type is required, closure-argument type can be omitted
            return ["Looks", "good", "to", "me"]
        }.failure { errorInfo -> [String] in
            return ["Looks", "bad"] // recover by returning value as [String] to fulfill
        }.failure { error, isCancelled -> [String] in   // NOTE: errorInfo = (error, isCancelled)
            XCTFail("Because of preceding failure-recovering, this failure should never be performed (just added for type-inference test)")
            return ["You", "shall", "not", "pass"]
        }.then { value, errorInfo -> String in
            return value!.joined(separator: " ")
        }.then { value, errorInfo -> Void in
            XCTAssertEqual(value!, "Looks good to me")
            return
        }
        
        // NOTE: you can't write like this
//        .then { value, (error, isCancelled) -> Void in
//                
//        }
    }
}
