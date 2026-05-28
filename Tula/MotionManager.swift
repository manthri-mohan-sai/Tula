//
//  MotionManager.swift
//  Tula
//
//  Created by Mohan Manthri on 28/05/26.
//


import Foundation
import CoreMotion

/// Wraps `CMMotionManager` to provide normalized device-orientation
/// data for subtle 3D effects in the UI (e.g., the focused-card tilt
/// in the Cards carousel — Apple Wallet uses the same pattern).
///
/// **Singleton with reference counting.** Views call `start()` on
/// appear and `stop()` on disappear; the underlying motion sensors
/// only run while at least one view needs them. When the Cards tab
/// is not visible, motion sensing is fully off — no battery cost.
///
/// **Why normalize to ~-1…1.** CoreMotion attitudes come in radians
/// (range ±π). Dividing by π gives a more useful 0-centered value
/// callers can multiply by their desired tilt amplitude in degrees,
/// e.g. `rollOffset * 8` → up to ±8° tilt at extreme device rolls.
///
/// **Low-pass filter (85% old + 15% new) smooths jitter** without
/// adding perceptible lag. Without smoothing the small sensor noise
/// shows up as a constant micro-jitter in the card tilt.
@Observable
@MainActor
final class MotionManager {

    static let shared = MotionManager()

    private let manager = CMMotionManager()
    private var refCount = 0

    /// Roll (left/right tilt), normalized to roughly -1…1 for typical
    /// hand-held device orientations. Smoothed.
    var rollOffset: Double = 0

    /// Pitch (forward/back tilt), normalized. Smoothed.
    var pitchOffset: Double = 0

    private init() {}

    /// Begin motion updates. Reference-counted — every `start()` call
    /// must be balanced with `stop()`. Safe to call when motion is
    /// already running; it just bumps the refcount.
    func start() {
        refCount += 1
        if refCount > 1 { return }

        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0   // 30Hz — smooth, cheap
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Radians → ~unit range. attitude.roll/pitch ∈ ±π.
            let targetRoll = motion.attitude.roll / .pi
            let targetPitch = motion.attitude.pitch / .pi
            // Low-pass filter. Higher α (here 0.85) = smoother, more lag.
            // 0.85/0.15 split balances "responsive" against "no jitter."
            self.rollOffset = self.rollOffset * 0.85 + targetRoll * 0.15
            self.pitchOffset = self.pitchOffset * 0.85 + targetPitch * 0.15
        }
    }

    /// End motion updates. Stops the underlying sensors only when the
    /// last caller has stopped — i.e. refcount drops to 0.
    func stop() {
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            manager.stopDeviceMotionUpdates()
            // Snap back to neutral so any view still rendering the
            // tilt doesn't end with a frozen offset.
            rollOffset = 0
            pitchOffset = 0
        }
    }
}