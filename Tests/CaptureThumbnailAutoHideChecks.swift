import Foundation
import Darwin

#if !BISCUIT_SMOKE
@main
#endif
@MainActor
enum CaptureThumbnailAutoHideChecks {
    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        do {
            try run()
        } catch {
            fputs("Capture thumbnail auto-hide checks failed: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        try check(CaptureThumbnailAutoHideTimer.defaultInterval == 8,
                  "the production shelf auto-hide interval is exactly eight seconds")

        var fireCount = 0
        let timer = CaptureThumbnailAutoHideTimer(interval: 0.30) { fireCount += 1 }
        defer { timer.cancel() }

        timer.reset()
        try check(timer.isScheduled, "reset schedules a one-shot timer")
        RunLoop.main.run(until: Date().addingTimeInterval(0.10))
        timer.reset()
        RunLoop.main.run(until: Date().addingTimeInterval(0.22))
        try check(fireCount == 0, "reset cancels the previous deadline")
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        try check(fireCount == 1 && !timer.isScheduled,
                  "the reset timer fires once and releases its scheduled state")

        timer.reset()
        timer.cancel()
        try check(!timer.isScheduled, "cancel removes the scheduled timer")
        RunLoop.main.run(until: Date().addingTimeInterval(0.34))
        try check(fireCount == 1, "cancel prevents a stale hide callback")

        print("Capture thumbnail auto-hide timer lifecycle checks passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(description: message) }
    }
}
