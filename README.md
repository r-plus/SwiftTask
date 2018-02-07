SwiftTask [![Circle CI](https://circleci.com/gh/ReactKit/SwiftTask/tree/swift%2F2.0.svg?style=svg)](https://circleci.com/gh/ReactKit/SwiftTask/tree/swift%2F2.0)
=========

[Promise](http://www.html5rocks.com/en/tutorials/es6/promises/) + pause + cancel + retry for Swift.

![SwiftTask](Screenshots/diagram.png)


## How to install

See [ReactKit Wiki page](https://github.com/ReactKit/ReactKit/wiki/How-to-install).


## Example

### Basic

```swift
// define task
let task = Task<Float, String, NSError> { fulfill, reject, configure in

    player.doSomething(completion: { (value: NSData?, error: NSError?) in
        if error == nil {
            fulfill("OK")
        }
        else {
            reject(error)
        }
    })

    // pause/resume/cancel configuration (optional)
    configure.pause = { [weak player] in
        player?.pause()
    }
    configure.resume = { [weak player] in
        player?.resume()
    }
    configure.cancel = { [weak player] in
        player?.cancel()
    }

}

// set success & failure
task.success { (value: String) -> Void in
    // do something with fulfilled value
}.failure { (error: NSError?, isCancelled: Bool) -> Void in
    // do something with rejected error
}

// you can call configured operations outside of Task-definition
task.pause()
task.resume()
task.cancel()
```

Notice that `player` has following methods, which will work nicely with `SwiftTask`:

- `doSomething(completion:)`
- `pause()` (optional)
- `resume()` (optional)
- `cancel()` (optional)

One of the best example would be [Alamofire](https://github.com/Alamofire/Alamofire) (networking library)
 as seen below.

### Using [Alamofire](https://github.com/Alamofire/Alamofire)

```swift
typealias AlamoFireTask = Task<String, NSError>

// define task
let task = AlamoFireTask { fulfill, reject, configure in

    Alamofire.download(.GET, "http://httpbin.org/stream/100", destination: somewhere)
      .response { request, response, data, error in

        if let error = error {
            reject(error)
            return
        }

        fulfill("OK")

    }

    return
}

// set then
task.then { (value: String?, errorInfo: AlamoFireTask.ErrorInfo?) -> Void in
    // do something with fulfilled value or rejected errorInfo
}
```

### Retry-able

`Task` can retry for multiple times by using `retry()` method.
For example, `task.retry(n)` will retry at most `n` times (total tries = `n+1`) if `task` keeps rejected, and `task.retry(0)` is obviously same as `task` itself having no retries.

This feature is extremely useful for unstable tasks e.g. network connection.
By implementing *retryable* from `SwiftTask`'s side, similar code is no longer needed for `player` (inner logic) class.

```swift
task.retry(2).success { ...
    // this closure will be called even when task is rejected for 1st & 2nd try
    // but finally fulfilled in 3rd try.
}
```

For more examples, please see XCTest cases.


## API Reference

### Task.init(initClosure:)

Define your `task` inside `initClosure`.

```swift
let task = Task<Float, NSString?, NSError> { fulfill, reject, configure in

    player.doSomethingWithCompletion { (value: NSString?, error: NSError?) in
        if error == nil {
            fulfill(value)
        }
        else {
            reject(error)
        }
    }
}
```

In order to pipeline future `task.value` or `task.errorInfo` (tuple of `(error: Error?, isCancelled: Bool)`) via `then()`/`success()`/`failure()`, you have to call `fulfill(value)` and/or `reject(error)` inside `initClosure`.

To add `pause`/`resume`/`cancel` functionality to your `task`, use `configure` to wrap up the original one.

```swift
// NOTE: use weak to let task NOT CAPTURE player via configure
configure.pause = { [weak player] in
    player?.pause()
}
configure.resume = { [weak player] in
    player?.resume()
}
configure.cancel = { [weak player] in
    player?.cancel()
}
```

### task.then(_ thenClosure:) -> newTask

`task.then(thenClosure)` will return a new task where `thenClosure` will be invoked when `task` is either **fulfilled** or **rejected**.

This case is similar to JavaScript's `promise.then(onFulfilled, onRejected)`.

`thenClosure` can be two types of closure form:

1. `thenClosure: (Value?, ErrorInfo?) -> Value2` (flow: *task => newTask*)

  ```swift
  // let task will be fulfilled with value "Hello"

  task.then { (value: String?, errorInfo: ErrorInfo?) -> String in
      // nil-check to find out whether task is fulfilled or rejected
      if errorInfo == nil {
          return "\(value!) World"
      }
      else {
          return "\(value!) Error"
      }
  }.success { (value: String) -> Void in
      println("\(value)")  // Hello World
      return"
  }
  ```

2. `thenClosure: (Value?, ErrorInfo?) -> Task` (flow: *task => task2 => newTask*)

  ```swift
  // let task will be fulfilled with value "Hello"

  task.then { (value: String?, errorInfo: ErrorInfo?) -> Task<Float, String, NSError> in
      if errorInfo == nil {
          // let task2 will be fulfilled with value "\(value!) Swift"
          let task2 = ...
          return task2
      }
      else {
          return someOtherTask
      }
  }.success { (value: String) -> Void in
      println("\(value)")  // Hello Swift
      return"
  }
  ```

### task.success(_ successClosure:) -> newTask

Similar to `then()` method, `task.success(successClosure)` will return a new task, but this time, `successClosure` will be invoked when task is **only fulfilled**.

This case is similar to JavaScript's `promise.then(onFulfilled)`.

```swift
// let task will be fulfilled with value "Hello"

task.success { (value: String) -> String in
  return "\(value) World"
}.success { (value: String) -> Void in
  println("\(value)")  // Hello World
  return"
}
```

### task.failure(_ failureClosure:) -> newTask

Just the opposite of `success()`, `task.failure(failureClosure)` will return a new task where `failureClosure` will be invoked when task is **only rejected/cancelled**.

This case is similar to JavaScript's `promise.then(undefined, onRejected)` or `promise.catch(onRejected)`.

```swift
// let task will be rejected with error "Oh My God"

task.success { (value: String) -> Void in
    println("\(value)") // never reaches here
    return
}.failure { (error: NSError?, isCancelled: Bool) -> Void in
    println("\(error!)")  // Oh My God
    return
}
```

### task.retry(_ tryCount:) -> newTask

See [Retry-able section](#retry-able).

### Task.all(_ tasks:) -> newTask

`Task.all(tasks)` is a new task that performs all `tasks` simultaneously and will be:

- fulfilled when **all tasks are fulfilled**
- rejected when **any of the task is rejected**

## Related Articles

- [SwiftTask（Promise拡張）を使う - Qiita](http://qiita.com/inamiy/items/0756339aee35849384c3) (Japanese, ver 1.0.0)


## Licence

[MIT](LICENSE)
