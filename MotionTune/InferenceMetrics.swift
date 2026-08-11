import Foundation
import Combine
import Darwin

/// Central tracker for everything measurable about the ZETIC inference path.
///
/// Categories covered:
/// 1. Inference performance — per-call latency, running count, time between
///    inferences, one-time model load time, and the configured execution mode.
/// 2. Resource footprint — resident memory delta across model load (KB).
/// 3. Output sanity — input/output ranges plus how often raw output needed
///    clamping, which flags normalization/scaling drift vs training.
///
/// All headline numbers are `@Published`, so a live-demo overlay can bind
/// directly to `avgLatencyMs`, `inferenceCount`, etc.
final class InferenceMetrics: ObservableObject {
    static let shared = InferenceMetrics()

    // --- Category 1: inference performance ---------------------------------
    @Published private(set) var inferenceCount = 0
    @Published private(set) var lastInferenceLatencyMs: Double = 0
    @Published private(set) var avgLatencyMs: Double = 0
    @Published private(set) var timeBetweenInferencesMs: Double = 0
    @Published private(set) var modelLoadMs: Double?
    @Published private(set) var backend = "unknown"

    // --- Category 2: resource footprint ------------------------------------
    @Published private(set) var memoryDeltaKB: Double?

    // --- Category 3: output sanity ------------------------------------------
    @Published private(set) var lastInputRange: (min: Float, max: Float)?
    @Published private(set) var lastOutputRange: (min: Float, max: Float)?
    @Published private(set) var clampedCount = 0

    // --- Live-demo headline -------------------------------------------------
    @Published private(set) var summary = "no inferences yet"

    private var totalLatencyMs: Double = 0
    private var lastInferenceTime: CFAbsoluteTime?
    private var baselineMemoryKB: Double?

    private init() {}

    /// Call just before starting the one-time model load. Captures the baseline
    /// memory footprint and returns the start timestamp for `recordModelLoad`.
    func markModelLoadStart() -> CFAbsoluteTime {
        baselineMemoryKB = Self.currentMemoryKB()
        return CFAbsoluteTimeGetCurrent()
    }

    /// Call after the model finished loading. Computes load duration and the
    /// resident-memory delta caused by the load. `backend` is the configured
    /// execution mode when the SDK doesn't expose the runtime backend directly.
    func recordModelLoad(startedAt: CFAbsoluteTime, backend: String) {
        modelLoadMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        self.backend = backend
        if let baseline = baselineMemoryKB, let current = Self.currentMemoryKB() {
            memoryDeltaKB = current - baseline
        }
        print("[InferenceMetrics] model-load=\(String(format: "%.1f", modelLoadMs ?? 0))ms " +
              "backend=\(backend) " +
              "memory-delta=\(String(format: "%.1f", memoryDeltaKB ?? 0))KB")
        refreshSummary()
    }

    /// Call immediately after each `model.run(...)`. `input` is the normalized
    /// window fed to the model; `output` is the raw float outputs. `clampedTo`
    /// is the post-process clamp range, so `clampedCount` counts how often raw
    /// output fell outside it (a healthy model needs ~0).
    func recordInference(startTime: CFAbsoluteTime,
                         input: [Float],
                         output: [Float],
                         clampedTo range: ClosedRange<Float> = 0...1) {
        // Inference runs on a background queue during streaming, so compute the
        // numbers on the calling thread but publish on main so SwiftUI
        // observers always see consistent values.
        let latencyMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let inMin = input.min() ?? -1
        let inMax = input.max() ?? -1
        let outMin = output.min() ?? -1
        let outMax = output.max() ?? -1
        let clamped = output.filter { !range.contains($0) }.count
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let last = self.lastInferenceTime {
                self.timeBetweenInferencesMs = (startTime - last) * 1000
            }
            self.lastInferenceTime = startTime
            self.lastInferenceLatencyMs = latencyMs
            self.totalLatencyMs += latencyMs
            self.inferenceCount += 1
            self.avgLatencyMs = self.totalLatencyMs / Double(self.inferenceCount)
            self.lastInputRange = (inMin, inMax)
            self.lastOutputRange = (outMin, outMax)
            self.clampedCount += clamped
            print("[inference #\(self.inferenceCount)] latency=\(String(format: "%.2f", latencyMs))ms " +
                  "avg=\(String(format: "%.2f", self.avgLatencyMs))ms " +
                  "gap=\(String(format: "%.2f", self.timeBetweenInferencesMs))ms " +
                  "input=[\(String(format: "%.3f", Double(inMin))), \(String(format: "%.3f", Double(inMax)))] " +
                  "output=[\(String(format: "%.3f", Double(outMin))), \(String(format: "%.3f", Double(outMax)))] " +
                  "clamped=\(self.clampedCount)")
            self.refreshSummary()
        }
    }

    /// One-line human summary for glancing at during a live demo.
    func logSummary() {
        print("[InferenceMetrics summary] \(summary)")
        if let loadMs = modelLoadMs { print("  model-load=\(String(format: "%.1f", loadMs))ms") }
        if let deltaKB = memoryDeltaKB { print("  memory-delta=\(String(format: "%.1f", deltaKB))KB") }
        print("  backend=\(backend)")
        if let input = lastInputRange { print("  input-range=[\(String(format: "%.3f", Double(input.min))), \(String(format: "%.3f", Double(input.max)))]") }
        if let output = lastOutputRange { print("  output-range=[\(String(format: "%.3f", Double(output.min))), \(String(format: "%.3f", Double(output.max)))]") }
        print("  clamped=\(clampedCount)")
    }

    /// Reset all counters (start of a new session or take).
    func reset() {
        inferenceCount = 0
        lastInferenceLatencyMs = 0
        avgLatencyMs = 0
        timeBetweenInferencesMs = 0
        modelLoadMs = nil
        memoryDeltaKB = nil
        backend = "unknown"
        lastInputRange = nil
        lastOutputRange = nil
        clampedCount = 0
        totalLatencyMs = 0
        lastInferenceTime = nil
        baselineMemoryKB = nil
        summary = "no inferences yet"
    }

    private func refreshSummary() {
        let outMin = Double(lastOutputRange?.min ?? 0)
        let outMax = Double(lastOutputRange?.max ?? 0)
        summary = "\(inferenceCount) inferences · avg \(String(format: "%.2f", avgLatencyMs))ms · " +
                  "out [\(String(format: "%.2f", outMin)), \(String(format: "%.2f", outMax))]"
    }

    /// Current resident memory footprint in KB (mach task basic info).
    private static func currentMemoryKB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0
    }
}
