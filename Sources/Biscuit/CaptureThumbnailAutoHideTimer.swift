import Foundation

@MainActor
final class CaptureThumbnailAutoHideTimer {
    static let defaultInterval: TimeInterval = 8

    private var timer: Timer?
    private let interval: TimeInterval
    private let onFire: @MainActor () -> Void

    init(interval: TimeInterval? = nil, onFire: @escaping @MainActor () -> Void) {
        self.interval = interval ?? Self.defaultInterval
        self.onFire = onFire
    }

    var isScheduled: Bool { timer?.isValid == true }

    func reset() {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.onFire()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
