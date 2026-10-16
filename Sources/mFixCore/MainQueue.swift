import Foundation

extension Timer {
    @discardableResult
    static func onMain(after interval: TimeInterval, repeats: Bool = false, _ block: @escaping @MainActor () -> Void) -> Timer {
        scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in MainActor.assumeIsolated(block) }
    }
}

func onMain(after delay: TimeInterval? = nil, _ block: @escaping @MainActor () -> Void) {
    if let delay {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(block) }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(block) }
    }
}
