import Foundation
import Combine

/// Drives the menu bar icon's hop by publishing a frame index.
///
/// A timer, not SwiftUI animation: MenuBarExtra collapses its label into an
/// NSStatusItem's image and title, which ignores SwiftUI animation the same way
/// it ignores padding. Swapping the published index re-renders the label, and
/// that is the only lever available.
///
/// It runs only while something is actually happening. A permanent animation in
/// the menu bar would make redrawing the icon the most expensive thing this app
/// does — it scans every 30s and spawns the CLI every 6 minutes, both cheaper
/// than a 12fps timer left running all day.
@MainActor
final class IconBounce: ObservableObject {
    @Published private(set) var frame = 0

    private var timer: Timer?

    var isAnimating: Bool { timer != nil }

    /// Fast enough to read as a hop, slow enough that the beat of rest at the
    /// end of the sequence lands.
    private static let interval: TimeInterval = 0.08

    func start() {
        guard timer == nil else { return }
        frame = 0
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.frame = (self.frame + 1) % MenuIcon.bounceSequence.count
            }
        }
    }

    /// Stops and returns to the resting frame. Invalidating matters: a timer
    /// that only stops changing the frame still wakes the CPU forever.
    func stop() {
        timer?.invalidate()
        timer = nil
        frame = 0
    }

    deinit {
        timer?.invalidate()
    }
}
