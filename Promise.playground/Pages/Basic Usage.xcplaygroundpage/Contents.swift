import Foundation
import PlaygroundSupport
import Promise

let val = Promise<Int>()

val.then { v in
    print("got: \(v)")
}

val.fulfill(1)
val.fulfill(2)

// - - - - - - - - - - - - - - - - - - - - - - - - - - -
// Run the playground so the `dispatch_async()`s work
PlaygroundPage.current.needsIndefiniteExecution = true
