import Foundation
import PlaygroundSupport
import Promise

func promisedString(_ str: String) -> Promise<String> {
    return Promise<String>(work: { fulfill, _ in
        print("sleeping…")
        sleep(1)
        print("done sleeping")
        fulfill(str)
    })
}

promisedString("simple example").then({ result in
    print("Got result: ", result)
})

print("after creating promise")

// - - - - - - - - - - - - - - - - - - - - - - - - - - -
// Run the playground so the `dispatch_async()`s work
PlaygroundPage.current.needsIndefiniteExecution = true
