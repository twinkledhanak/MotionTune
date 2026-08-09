import Foundation
internal import CoreMotion
import Combine

/**
@TODO:
 1. Your pitch normalization isn't centered
 2. No smoothing yet.
 
 
 */

final class MotionManager: ObservableObject {
    @Published var isTracking = false
    @Published var sampleCount = 0

    // At any instant, we capture below variables: Attitude, Gravity, RotationRate, UserAcceleration
    @Published var attitude = (roll: 0.0, pitch: 0.0, yaw: 0.0)
    @Published var gravity = CMAcceleration(x: 0, y: 0, z: 0)
    @Published var rotationRate = CMRotationRate(x: 0, y: 0, z: 0)
    @Published var userAcceleration = CMAcceleration(x: 0, y: 0, z: 0)

    // MARK: - Time-series arrays (normalized 0...1 values)
    @Published var pitchSeries: [Double] = []
    @Published var gravitySeries: [Double] = []
    @Published var rotationSeries: [Double] = []
    @Published var accelYSeries: [Double] = []
    @Published var rollSeries: [Double] = []

    // MARK: - Time-series arrays (raw MIDI curves — what you send out)
    @Published var pitchBendSeries: [Int] = []   // 0...16383, center 8192
    @Published var cc11Series: [Int] = []          // 0...127
    @Published var cc1Series: [Int] = []           // 0...127

    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 1.0 / 60.0
    private let sensitivity: Double = 2.5
    private let gravitySensitivity: Double = 1.5
    private let verticalMotionMix: Double = 2.0

    var isAvailable: Bool {
        motionManager.isDeviceMotionAvailable
    }

    // MARK: - Normalization helper (now clamped to 0...1)
    private func normalize(_ value: Double, min: Double, max: Double) -> Double {
        let t = (value - min) / (max - min)
        return Swift.min(1.0, Swift.max(0.0, t))
    }

    // MARK: - Sensitivity boost (centered at 0.5, exaggerates deviation from center)
    private func boost(_ norm: Double, sensitivity: Double) -> Double {
        let centered = (norm - 0.5) * sensitivity
        return Swift.min(1.0, Swift.max(0.0, 0.5 + centered))
    }

    // MARK: - MIDI curve mappers
    // Pitch bend is 14-bit, centered at 8192. Feed it a normalized value
    // that's already centered at 0.5 (i.e. 0 = full bend down, 1 = full bend up).
    private func toPitchBend(_ norm: Double) -> Int {
        let value = Int((norm * 16383.0).rounded())
        return Swift.min(16383, Swift.max(0, value))
    }

    // Standard 7-bit CC value (CC11, CC1, CC74, etc.)
    private func toMIDI7(_ norm: Double) -> Int {
        let value = Int((norm * 127.0).rounded())
        return Swift.min(127, Swift.max(0, value))
    }

    func start() {
        guard isAvailable, !motionManager.isDeviceMotionActive else { return }
        sampleCount = 0
        pitchSeries.removeAll()
        gravitySeries.removeAll()
        rotationSeries.removeAll()
        accelYSeries.removeAll()
        rollSeries.removeAll()
        pitchBendSeries.removeAll()
        cc11Series.removeAll()
        cc1Series.removeAll()
        motionManager.deviceMotionUpdateInterval = updateInterval

        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.sampleCount += 1

            // 1. Capture raw sensor values
            let rawPitch = motion.attitude.pitch
            let rawGravityY = motion.gravity.y
            let rawRotationZ = motion.rotationRate.z
            let rawAccelY = motion.userAcceleration.y
            let rawRoll = motion.attitude.roll

            // Update published raw values for UI
            self.attitude = (
                roll: rawRoll,
                pitch: rawPitch,
                yaw: motion.attitude.yaw
            )
            self.gravity = motion.gravity
            self.rotationRate = motion.rotationRate
            self.userAcceleration = motion.userAcceleration

            // 2. Normalize each axis to 0...1 with working ranges that match real motion
            //    (narrow ranges + sensitivity boost = small moves swing the full MIDI range)
            let pitchNorm = self.normalize(rawPitch, min: -0.6, max: 0.6)
            let gravityNorm = self.normalize(rawGravityY, min: -1.0, max: 1.0)
            let rotationNorm = self.normalize(rawRotationZ, min: -4.0, max: 4.0)
            let accelYNorm = self.normalize(rawAccelY, min: -2.0, max: 2.0)
            let rollNorm = self.normalize(rawRoll, min: -0.8, max: 0.8)

            let pitchBoosted = self.boost(pitchNorm, sensitivity: self.sensitivity)
            let gravityBoosted = self.boost(gravityNorm, sensitivity: self.gravitySensitivity)
            let rotationBoosted = self.boost(rotationNorm, sensitivity: self.sensitivity)
            let accelYBoosted = self.boost(accelYNorm, sensitivity: self.sensitivity)
            let rollBoosted = self.boost(rollNorm, sensitivity: self.sensitivity)

            // 3. Append normalized values to time-series arrays
            self.pitchSeries.append(pitchBoosted)
            self.gravitySeries.append(gravityBoosted)
            self.rotationSeries.append(rotationBoosted)
            self.accelYSeries.append(accelYBoosted)
            self.rollSeries.append(rollBoosted)

            // 4. Map to actual MIDI curve values for this instrument profile
            //    attitude.pitch + userAcceleration.y -> Pitch Bend (glide + vertical raise)
            //    gravity.y       -> CC11 (Expression / dynamics)
            //    rotationRate.z  -> CC1  (Modulation / vibrato)
            let verticalMotion = (accelYBoosted - 0.5) * self.verticalMotionMix
            let combinedPitch = Swift.min(1.0, Swift.max(0.0, pitchBoosted + verticalMotion))
            let pitchBend = self.toPitchBend(combinedPitch)
            let cc11 = Swift.max(15, self.toMIDI7(gravityBoosted))
            let cc1 = self.toMIDI7(rotationBoosted)

            self.pitchBendSeries.append(pitchBend)
            self.cc11Series.append(cc11)
            self.cc1Series.append(cc1)
        }
        isTracking = true
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isTracking = false
    }
}
