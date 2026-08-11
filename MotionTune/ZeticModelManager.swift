import Foundation
import Combine
import ZeticMLange

/// Wraps the ZETIC Melange model lifecycle (step 1): download + load
/// `twinkledhanak/MotionTune` v4, and expose its declared I/O for the
/// inference steps that come next.
final class ZeticModelManager: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle

    /// Step 6 output: the model-refined CC11 curve, aligned to the 60Hz
    /// recording (last 4.0s window replaced with the model's output, upsampled
    /// 20Hz -> 60Hz). Empty until an inference succeeds.
    @Published private(set) var refinedCC11: [Int] = []

    private var model: ZeticMLangeModel?

    /// Declared input tensors of the loaded model (name, shape, dtype).
    /// Empty until the model is `ready` — used to build inputs in step 2.
    var inputTensors: [TensorInfo] {
        model?.inputTensors ?? []
    }

    /// Declared output tensors of the loaded model.
    var outputTensors: [Tensor] {
        model?.getOutputTensors() ?? []
    }

    private let sourceHz: Double = 60.0
    private let modelHz: Double = 20.0
    private let windowLength = 80

    /// Steps 1–6: resample cc11 60Hz→20Hz, window the last 80 samples (4.0s),
    /// per-window min–max normalize to 0...1, pack [1, 80, 1] float32, run the
    /// model, then post-process the output back to MIDI CC11 (0...127) aligned
    /// to the 60Hz recording in `refinedCC11`.
    func runInference(cc11: [Int]) {
        refinedCC11 = []
        guard let model else {
            print("ZeticMLange: model not ready — skipping inference")
            return
        }
        guard !cc11.isEmpty else {
            print("ZeticMLange: no CC11 data to infer on")
            return
        }

        // 1. Resample 60Hz -> 20Hz (light 3-tap low-pass, then decimate by 3)
        let resampled = Self.resampleTo20Hz(cc11)

        // 2. Window: last 80 resampled samples = exactly 4.0s, zero-padded prefix
        var window = [Float](repeating: 0, count: windowLength)
        let take = min(resampled.count, windowLength)
        window.replaceSubrange((windowLength - take)...,
                               with: resampled.suffix(take))

        // 3. Per-window min–max normalize to 0...1 (mirrors training)
        let normalized = Self.normalizeMinMax(window)

        print("ZeticMLange — inference input:")
        print("  recorded=\(cc11.count) @\(Int(sourceHz))Hz → resampled=\(resampled.count) @\(Int(modelHz))Hz → window=\(windowLength) (=\(Double(windowLength) / modelHz)s)")
        print("  normalized window: min=\(normalized.min() ?? -1), max=\(normalized.max() ?? -1), first=\(normalized.first ?? -1), last=\(normalized.last ?? -1)")

        // 4. Pack [1, 80, 1] float32
        let data = normalized.withUnsafeBytes { Data($0) }
        let input = Tensor(data: data, dataType: BuiltinDataType.float32, shape: [1, 80, 1])

        // 5. Run
        do {
            let outputs = try model.run(inputs: [input])
            guard let output = outputs.first else {
                print("ZeticMLange — run returned no outputs")
                return
            }
            let floats = output.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let min = floats.min() ?? -1
            let max = floats.max() ?? -1
            let mean = floats.isEmpty ? 0 : floats.reduce(0, +) / Float(floats.count)
            print("ZeticMLange — inference output:")
            print("  shape=\(output.shape) dtype=\(output.dataType) count=\(output.count())")
            print("    min=\(min) max=\(max) mean=\(mean)")

            // 6. Post-process: clamp 0...1, scale x127 -> MIDI CC11, then
            //    upsample 20Hz -> 60Hz (hold x3) and overlay the last window.
            let midi = floats.map { v -> Int in
                let c = Swift.min(1.0, Swift.max(0.0, v))
                return Swift.min(127, Swift.max(0, Int((c * 127.0).rounded())))
            }
            var refined = cc11
            let up = midi.count * 3
            let start = Swift.max(0, refined.count - up)
            for (i, v) in midi.enumerated() {
                for j in 0..<3 {
                    let idx = start + i * 3 + j
                    if idx < refined.count { refined[idx] = v }
                }
            }
            refinedCC11 = refined
            print("  refined cc11: min=\(refined.min() ?? -1), max=\(refined.max() ?? -1), replaced last \(Swift.min(refined.count, up)) of \(refined.count) samples")
        } catch {
            print("ZeticMLange — run failed: \(error)")
        }
    }

    /// 60Hz -> 20Hz: 3-tap moving average, then keep every 3rd sample.
    private static func resampleTo20Hz(_ cc11: [Int]) -> [Float] {
        guard cc11.count >= 3 else {
            return cc11.map { Float($0) }
        }
        var smoothed = [Float](repeating: 0, count: cc11.count)
        for i in 0..<cc11.count {
            let lo = max(0, i - 1)
            let hi = min(cc11.count - 1, i + 1)
            smoothed[i] = (Float(cc11[lo]) + Float(cc11[i]) + Float(cc11[hi])) / 3.0
        }
        var out: [Float] = []
        for i in stride(from: 2, to: cc11.count, by: 3) {
            out.append(smoothed[i])
        }
        return out
    }

    /// Per-window min–max to 0...1. Flat windows stay all-zero.
    private static func normalizeMinMax(_ window: [Float]) -> [Float] {
        guard let mn = window.min(), let mx = window.max(), mx - mn > 1e-6 else {
            return window
        }
        return window.map { ($0 - mn) / (mx - mn) }
    }

    private func debugPrintInputsOutputs() {
        print("ZeticMLange — declared inputs:")
        for info in inputTensors {
            print("  input: name=\(info.name) shape=\(info.shape) dtype=\(info.dtype)")
        }
        print("ZeticMLange — declared outputs:")
        for t in outputTensors {
            print("  output: shape=\(t.shape) dtype=\(t.dataType) count=\(t.count())")
        }
    }

    func load() async {
        guard model == nil else { return }
        state = .loading
        do {
            let model = try await ZeticMLangeModel(
                personalKey: ZeticKey.personalKey,
                name: "twinkledhanak/MotionTune",
                version: 4,
                modelMode: .RUN_AUTO,
                onDownload: { progress in
                    Task { @MainActor in
                        self.state = .downloading(Double(progress))
                    }
                }
            )
            self.model = model
            state = .ready
            debugPrintInputsOutputs()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
