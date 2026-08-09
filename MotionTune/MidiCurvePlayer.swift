import Foundation
import AVFoundation
import Combine

enum Instrument: String, CaseIterable, Identifiable {
    case theremin = "Theremin"
    case piano = "Piano"
    case violin = "Violin"

    var id: String { rawValue }
}

final class MidiCurvePlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var instrument: Instrument = .theremin

    private let engine = AVAudioEngine()
    private let baseFrequency: Double = 261.63
    private let sampleRate: Double = 44100
    private let samplesPerCurveStep: Double = 44100.0 / 60.0
    private let vibratoRate: Double = 5.0
    private let pulseDecay: Double = 12.0
    private let pulseMix: Double = 0.3
    private let violinDetuneCents: Double = 6.0
    // Master output: -6 dB headroom plus a soft tanh limiter, so stacked
    // voices (melody + pulse + pad) can never exceed 1.0. The limiter runs
    // nearly linear in normal playing and only compresses rare summed peaks.
    private let masterGain: Double = 0.5
    private let softLimitDrive: Double = 1.0

    private var freqCurve: [Double] = []
    private var ampCurve: [Double] = []
    private var vibCurve: [Double] = []

    private var sourceNode: AVAudioSourceNode?
    private var frameCount: Int64 = 0
    private var phase: Double = 0
    private var string2Phase: Double = 0
    private var smoothFreq: Double = 261.63
    private var smoothAmp: Double = 0
    private var smoothVib: Double = 0
    private var currentNote: Int = -1
    private var noteAge: Double = 0
    private var pulseAge: Double = 0
    private var accentFreq: Double = 130.81
    private var accentVel: Double = 0
    private var accentPhase: Double = 0
    private var didFinish = false

    // Note segmentation (melody mode): per-note attack/decay envelopes and
    // re-struck repeats. noteOnsetFrame[i] = absolute frame at which the note
    // containing curve step i begins, or -1 when segmentation is disabled.
    private var perNoteEnvelope = false
    private var noteOnsetFrame: [Double] = []
    private var noteOnsetTrack: Double = -1

    // Motion-triggered pulse: step indices where the hand "arrives" at a
    // position (stops after moving), so the pulse follows the motion shape
    // instead of a fixed grid.
    private var pulseTriggers: Set<Int> = []
    private var pulseLastStep: Int = -1

    // Harmonic anchor (melody mode): a looping I-IV-V-I progression in G that
    // plays as a soft root+fifth pad, and the melody snaps toward the current
    // chord's tones. Chord tones are pitch classes; register (roll) still
    // shifts octaves freely.
    private let chordSteps: [Int] = [0, 1, 2, 0]        // G, C, D, G
    private let stepsPerChord = 150                     // ~2.5s per chord @60fps
    private let chordRoots: [Int] = [55, 60, 62, 55]    // G3, C4, D4, G3
    private static let chordPitchClasses: [[Int]] = [
        [7, 11, 2],  // G  (G B D)
        [0, 4, 7],   // C  (C E G)
        [2, 6, 9],   // D  (D F# A)
        [7, 11, 2],  // G
    ]
    private let padMix: Double = 0.22
    private var chordPhases: [Double] = Array(repeating: 0, count: 12)
    private var chordIdx = 0
    // Pad envelope: slew-based, with a 0.15s release so chord changes and stop()
    // fade to silence instead of switching or cutting at full gain.
    private var padFade: Double = 0
    private var padFadeTarget: Double = 0
    private var padPendingChord = -1
    private var padReleaseRequested = false

    // Audio export: records the live mix to a file via a mixer tap, so the
    // exported WAV is exactly what's heard (melody + pad + pulse).
    private var exportFile: AVAudioFile?
    private var exportURL: URL?
    private var exportCompletion: ((Result<URL, Error>) -> Void)?

    /// Load a recorded motion series for playback.
    /// `quantized` snaps the pitch to the G-major scale across a wide range
    /// (melody mode); otherwise it glides continuously (classic theremin).
    func loadSeries(pitchBend: [Int], cc11: [Int], cc1: [Int], roll: [Double] = [], quantized: Bool) {
        let count = min(pitchBend.count, min(cc11.count, cc1.count))
        guard count > 0 else { return }

        if quantized {
            // Narrow ladder (one octave) so each hand step is a small move, with
            // the pitch snapped to the nearest G-major note. Short blips (fast
            // hand passages through in-between notes) are merged into the
            // previous note so they don't articulate as extra notes.
            let semitones = (0..<count).map { (Double(pitchBend[$0]) - 8192.0) / 8192.0 * 7.0 }
            let hasRoll = roll.count == count
            let snapped: [Int]
            if hasRoll {
                snapped = semitones.enumerated().map { step, semis in
                    let scaleNote = snapToGMajor(60.0 + semis).rounded()
                    let chordNote = snapToChord(scaleNote, chordIndex: chordIndex(at: step))
                    return Int(chordNote) + registerShift(from: roll[step])
                }
            } else {
                snapped = semitones.enumerated().map { step, semis in
                    let scaleNote = snapToGMajor(60.0 + semis).rounded()
                    let chordNote = snapToChord(scaleNote, chordIndex: chordIndex(at: step))
                    return Int(chordNote)
                }
            }
            let cleaned = cleanNoteRuns(snapped, minSteps: 6)
            freqCurve = cleaned.map { 440.0 * pow(2.0, (Double($0) - 69.0) / 12.0) }
            segmentNotes(pitches: cleaned, cc11: cc11.prefix(count).map { Double($0) / 127.0 })
        } else {
            freqCurve = (0..<count).map { i in
                let semitones = (Double(pitchBend[i]) - 8192.0) / 8192.0 * 2.0
                return baseFrequency * pow(2.0, semitones / 12.0)
            }
            perNoteEnvelope = false
            noteOnsetFrame = []
        }
        pulseTriggers = computeMotionPulse(freqCurve)
        ampCurve = cc11.prefix(count).map { Double($0) / 127.0 }
        vibCurve = cc1.prefix(count).map { Double($0) / 127.0 * 0.08 }
    }

    /// Find "arrival" points in the pitch curve: places where the hand stops
    /// after having moved. These become pulse accents, so the rhythm follows
    /// the shape of the motion instead of a fixed grid.
    private func computeMotionPulse(_ freqs: [Double]) -> Set<Int> {
        let count = freqs.count
        var moving = [Bool](repeating: false, count: count)
        let minMoveSemis = 0.08
        for i in 1..<count {
            let semis = 12.0 * abs(log2(freqs[i] / freqs[i - 1]))
            moving[i] = semis > minMoveSemis
        }
        var triggers = Set<Int>()
        let window = 6
        for i in 1..<count where !moving[i] {
            let start = max(0, i - window)
            var wasMoving = false
            var peakSpeed = 0.0
            for j in start..<i {
                wasMoving = wasMoving || moving[j]
                let semis = 12.0 * abs(log2(freqs[j] / freqs[max(0, j - 1)]))
                peakSpeed = max(peakSpeed, semis)
            }
            if wasMoving && peakSpeed > 0.4 {
                triggers.insert(i)
            }
        }
        return triggers
    }

    /// Split the quantized pitch curve into note segments. A new note starts
    /// where the pitch changes (plateau jump) or where CC11 dips below 60% of
    /// its recent peak (the volume-hand separation a player uses between
    /// notes) — which also re-strikes repeated same-pitch notes.
    private func segmentNotes(pitches: [Int], cc11: [Double]) {
        let count = pitches.count
        var onsetStep = [Int](repeating: 0, count: count)
        var currentOnset = 0
        let peakWindow = 20
        for i in 1..<count {
            if pitches[i] != pitches[i - 1] {
                currentOnset = i
            } else if let peak = cc11[max(0, i - peakWindow)...i].max(), peak > 0.05 {
                let dipLevel = 0.6 * peak
                if cc11[i] < dipLevel && cc11[i - 1] >= dipLevel {
                    currentOnset = i
                }
            }
            onsetStep[i] = currentOnset
        }
        onsetStep[0] = 0
        noteOnsetFrame = onsetStep.map { Double($0) * samplesPerCurveStep }
        perNoteEnvelope = true
    }

    /// G-major scale degrees relative to the root (G A B C D E F#).
    private static let gMajorScale: [Int] = [0, 2, 4, 7, 9, 11]

    /// Snap a continuous MIDI note value to the nearest note of the G-major scale.
    private func snapToGMajor(_ note: Double) -> Double {
        let octaveRoot = (note / 12.0).rounded(.down) * 12.0
        let semitoneInOctave = note - octaveRoot
        var best = octaveRoot + Double(Self.gMajorScale[0])
        var bestDistance = abs(semitoneInOctave - Double(Self.gMajorScale[0]))
        for s in Self.gMajorScale.dropFirst() {
            let d = abs(semitoneInOctave - Double(s))
            if d < bestDistance {
                bestDistance = d
                best = octaveRoot + Double(s)
            }
        }
        let octaveDistance = abs(semitoneInOctave - 12.0)
        if octaveDistance < bestDistance {
            best = octaveRoot + 12.0
        }
        return best
    }

    /// Register switch from the roll (left/right tilt) axis: -1, 0 or +1
    /// octave. The bands have a wide middle dead-zone so holding the phone
    /// level stays on register 0; `cleanNoteRuns` merges any blips at the edges.
    private func registerShift(from roll: Double) -> Int {
        if roll < 0.35 { return -12 }
        if roll > 0.65 { return 12 }
        return 0
    }

    /// Chord index for a curve step, looping the I-IV-V-I progression.
    private func chordIndex(at step: Int) -> Int {
        chordSteps[(step / stepsPerChord) % chordSteps.count]
    }

    /// Snap a scale note toward the current chord's tones when it's a half-step
    /// away (chord-tone weighting). Notes already on the chord stay put; the
    /// correction is at most one scale step, so the melody never gets mangled.
    private func snapToChord(_ note: Double, chordIndex: Int) -> Double {
        let chordPCs = Self.chordPitchClasses[chordIndex]
        let pc = Int(note.rounded()) % 12
        var bestPC = chordPCs[0]
        var bestDistance = 12
        for candidate in chordPCs {
            let d = Self.pitchClassDistance(pc, candidate)
            if d < bestDistance {
                bestDistance = d
                bestPC = candidate
            }
        }
        var offset = bestPC - pc
        if offset > 6 { offset -= 12 }
        if offset < -6 { offset += 12 }
        let chordNote = note + Double(offset)
        return abs(chordNote - note) <= 1.0 ? chordNote : note
    }

    private static func pitchClassDistance(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b) % 12
        return min(d, 12 - d)
    }

    /// Replace any run of the same note shorter than `minSteps` curve steps with
    /// the previous note, so fast hand passages don't sound like extra notes.
    private func cleanNoteRuns(_ notes: [Int], minSteps: Int) -> [Int] {
        guard notes.count > 1 else { return notes }
        var result = notes
        var i = 0
        while i < notes.count {
            let start = i
            let note = notes[i]
            while i < notes.count && notes[i] == note { i += 1 }
            if i - start < minSteps {
                let fill: Int
                if start > 0 {
                    fill = result[start - 1]
                } else if i < notes.count {
                    fill = result[i]
                } else {
                    fill = note
                }
                for j in start..<i { result[j] = fill }
            }
        }
        return result
    }

    func play() {
        guard !freqCurve.isEmpty, !isPlaying else { return }
        frameCount = 0
        phase = 0
        string2Phase = 0
        smoothFreq = baseFrequency
        smoothAmp = 0
        smoothVib = 0
        currentNote = -1
        noteAge = 0
        pulseAge = 0
        accentFreq = baseFrequency / 2.0
        accentVel = 0
        accentPhase = 0
        noteOnsetTrack = -1
        pulseLastStep = -1
        didFinish = false
        padFade = 0
        padFadeTarget = 0
        padPendingChord = -1
        padReleaseRequested = false
        setupSourceIfNeeded()
        do {
            try engine.start()
            isPlaying = true
        } catch {
            isPlaying = false
        }
    }

    func playForExport(to url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !freqCurve.isEmpty, !isPlaying else { return }
        exportURL = url
        exportCompletion = completion
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        do {
            exportFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            exportURL = nil
            exportCompletion = nil
            completion(.failure(error))
            return
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self, let file = self.exportFile else { return }
            try? file.write(from: buffer)
        }
        play()
    }

    func stop() {
        if exportFile != nil {
            engine.mainMixerNode.removeTap(onBus: 0)
            exportFile = nil
            exportURL = nil
            exportCompletion = nil
        }
        if isPlaying {
            // Graceful ~0.15s pad release; the render loop calls finishPlayback
            // once the pad reaches silence.
            padReleaseRequested = true
            padFadeTarget = 0
            return
        }
        engine.stop()
        frameCount = 0
        phase = 0
        smoothFreq = baseFrequency
        smoothAmp = 0
        smoothVib = 0
        chordIdx = 0
        padFade = 0
        padFadeTarget = 0
        padPendingChord = -1
        isPlaying = false
    }

    private func setupSourceIfNeeded() {
        guard sourceNode == nil else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }

            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let channels = buffers.map { $0.mData?.assumingMemoryBound(to: Float.self) }
            let totalFrames = Double(self.freqCurve.count) * self.samplesPerCurveStep

            var localFrame = self.frameCount
            var localPhase = self.phase
            var localString2Phase = self.string2Phase
            var localFreq = self.smoothFreq
            var localAmp = self.smoothAmp
            var localVib = self.smoothVib
            var localNote = self.currentNote
            var localNoteAge = self.noteAge
            var localPulseAge = self.pulseAge
            var localAccentFreq = self.accentFreq
            var localAccentVel = self.accentVel
            var localAccentPhase = self.accentPhase
            var localOnsetTrack = self.noteOnsetTrack
            var localPulseLastStep = self.pulseLastStep
            var localChordPhases = self.chordPhases
            var localChordIdx = self.chordIdx
            var localPadFade = self.padFade
            var localPadFadeTarget = self.padFadeTarget
            var localPadPendingChord = self.padPendingChord
            let localPadReleaseRequested = self.padReleaseRequested

            let isKeyboard = self.instrument == .piano
            let isViolin = self.instrument == .violin
            let isMelody = self.perNoteEnvelope && self.noteOnsetFrame.count == self.freqCurve.count

            for frame in 0..<Int(frameCount) {
                var value: Float = 0
                let idx = min(Int(Double(localFrame) / self.samplesPerCurveStep), self.freqCurve.count - 1)
                let playing = Double(localFrame) < totalFrames
                if playing {
                    let targetFreq = self.freqCurve[idx]
                    let targetAmp = self.ampCurve[idx]
                    let targetVib = self.vibCurve[idx]

                    localFreq += (targetFreq - localFreq) * 0.005
                    localAmp += (targetAmp - localAmp) * 0.005
                    localVib += (targetVib - localVib) * 0.005

                    let time = Double(localFrame) / self.sampleRate
                    let useVibrato = self.instrument != .piano
                    // Violin: shallow, irregular vibrato (real bowing is uneven)
                    let vibrato: Double
                    if isViolin {
                        let wobble1 = sin(2.0 * .pi * 5.0 * time)
                        let wobble2 = sin(2.0 * .pi * 7.3 * time + 0.9)
                        vibrato = 1.0 + localVib * 0.4 * (0.7 * wobble1 + 0.3 * wobble2)
                    } else {
                        vibrato = 1.0 + (useVibrato ? localVib * sin(2.0 * .pi * self.vibratoRate * time) : 0)
                    }

                    var noteEnv: Double = 1.0
                    if isMelody {
                        // Note segmentation: re-strike whenever a new note segment
                        // begins (pitch change or CC11 dip), even on a repeat.
                        let onset = self.noteOnsetFrame[idx]
                        if onset != localOnsetTrack {
                            localOnsetTrack = onset
                            localNoteAge = 0
                        }
                        localNoteAge += 1.0 / self.sampleRate
                        let attack = min(1.0, localNoteAge / 0.01)
                        let decay = exp(-localNoteAge * 1.6)
                        noteEnv = attack * (decay < 0.001 ? 0 : decay)
                        if isViolin {
                            let detune = pow(2.0, self.violinDetuneCents / 1200.0)
                            localPhase += 2.0 * .pi * localFreq * vibrato / self.sampleRate
                            localString2Phase += 2.0 * .pi * localFreq * detune * vibrato / self.sampleRate
                        } else {
                            localPhase += 2.0 * .pi * localFreq * vibrato / self.sampleRate
                        }
                    } else if isKeyboard {
                        // Quantize glide to discrete semitone steps (struck keys, not a bow)
                        let midiNote = Int((69.0 + 12.0 * log2(localFreq / 440.0)).rounded())
                        if midiNote != localNote {
                            localNote = midiNote
                            localNoteAge = 0
                        }
                        localNoteAge += 1.0 / self.sampleRate
                        // Percussive envelope: fast attack, exponential decay
                        let attack = min(1.0, localNoteAge / 0.008)
                        let decay = exp(-localNoteAge * 1.8)
                        noteEnv = attack * (decay < 0.001 ? 0 : decay)
                        let noteFreq = 440.0 * pow(2.0, (Double(midiNote) - 69.0) / 12.0)
                        localPhase += 2.0 * .pi * noteFreq * vibrato / self.sampleRate
                    } else if isViolin {
                        // Two detuned oscillators (chorus) -> warm, fat string sound
                        let detune = pow(2.0, self.violinDetuneCents / 1200.0)
                        localPhase += 2.0 * .pi * localFreq * vibrato / self.sampleRate
                        localString2Phase += 2.0 * .pi * localFreq * detune * vibrato / self.sampleRate
                    } else {
                        localPhase += 2.0 * .pi * localFreq * vibrato / self.sampleRate
                    }

                    if isViolin {
                        value = Float((self.violinWave(localPhase) + self.violinWave(localString2Phase)) * localAmp * noteEnv)
                    } else {
                        value = Float(self.wave(localPhase, instrument: self.instrument) * localAmp * noteEnv)
                    }

                    // Rhythmic pulse: short percussive accent fired when the
                    // hand "arrives" at a position (motion shape), not a fixed
                    // grid. Velocity follows the motion dynamics (CC11).
                    localPulseAge += 1.0 / self.sampleRate
                    if self.pulseTriggers.contains(idx), idx != localPulseLastStep, localPulseAge > 0.03 {
                        localPulseLastStep = idx
                        localPulseAge = 0
                        localAccentFreq = localFreq / 2.0
                        localAccentVel = localAmp
                        localAccentPhase = 0
                    }
                    localAccentPhase += 2.0 * .pi * localAccentFreq / self.sampleRate
                    let accEnv = localAccentVel * exp(-localPulseAge * self.pulseDecay) * self.pulseMix
                    let accent = sin(localAccentPhase) * 0.6 + sin(2 * localAccentPhase) * 0.4
                    value += Float(accent * accEnv)
                }

                // Harmonic pad: soft root+fifth+octave, gated by a slew
                // envelope. Runs on every frame (including the tail after the
                // curve), so chord changes fade out (release) before the chord
                // actually swaps, and stop()/end-of-recording fade to silence
                // instead of cutting at full gain.
                if isMelody {
                    let chord = self.chordSteps[(idx / self.stepsPerChord) % self.chordSteps.count]
                    if localPadReleaseRequested || !playing {
                        localPadFadeTarget = 0
                    } else if localPadFade > 0.99 && chord != localChordIdx {
                        localPadFadeTarget = 0
                        localPadPendingChord = chord
                    } else if localPadFade <= 0.001 {
                        if localPadPendingChord >= 0 {
                            localChordIdx = localPadPendingChord
                            localPadPendingChord = -1
                        }
                        if !localPadReleaseRequested && playing {
                            localPadFadeTarget = 1
                        }
                    }
                    // Linear 0.15s fades in and out.
                    let slew = (1.0 / 0.15) / self.sampleRate
                    if localPadFade < localPadFadeTarget {
                        localPadFade = min(localPadFadeTarget, localPadFade + slew)
                    } else if localPadFade > localPadFadeTarget {
                        localPadFade = max(localPadFadeTarget, localPadFade - slew)
                    }
                    if localPadFade > 0.001 {
                        let root = self.chordRoots[localChordIdx]
                        let padFreq = 440.0 * pow(2.0, (Double(root) - 69.0) / 12.0)
                        let fifthFreq = padFreq * 3.0 / 2.0
                        localChordPhases[localChordIdx * 3] += 2.0 * .pi * padFreq / self.sampleRate
                        localChordPhases[localChordIdx * 3 + 1] += 2.0 * .pi * fifthFreq / self.sampleRate
                        localChordPhases[localChordIdx * 3 + 2] += 2.0 * .pi * padFreq * 2.0 / self.sampleRate
                        let pad = (sin(localChordPhases[localChordIdx * 3])
                            + 0.5 * sin(localChordPhases[localChordIdx * 3 + 1])
                            + 0.18 * sin(localChordPhases[localChordIdx * 3 + 2]))
                            * self.padMix * localPadFade
                        value += Float(pad)
                    }
                }

                // Playback is over once the curve has finished and (in melody
                // mode) the pad has faded to silence. stop() requests the same
                // release path via padReleaseRequested.
                if !self.didFinish
                    && (localPadReleaseRequested || !playing)
                    && (!isMelody || localPadFade <= 0.001) {
                    self.didFinish = true
                    DispatchQueue.main.async { [weak self] in
                        self?.finishPlayback()
                    }
                }

                // -6 dB headroom + soft limiter before hitting the output.
                value = Float(tanh(Double(value) * self.softLimitDrive) * self.masterGain)
                channels.forEach { $0?[frame] = value }
                localFrame += 1
            }

            self.frameCount = localFrame
            self.phase = localPhase
            self.string2Phase = localString2Phase
            self.smoothFreq = localFreq
            self.smoothAmp = localAmp
            self.smoothVib = localVib
            self.currentNote = localNote
            self.noteAge = localNoteAge
            self.noteOnsetTrack = localOnsetTrack
            self.pulseLastStep = localPulseLastStep
            self.pulseAge = localPulseAge
            self.accentFreq = localAccentFreq
            self.accentVel = localAccentVel
            self.accentPhase = localAccentPhase
            self.chordPhases = localChordPhases
            self.chordIdx = localChordIdx
            self.padFade = localPadFade
            self.padFadeTarget = localPadFadeTarget
            self.padPendingChord = localPadPendingChord
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    /// Pure-DSP timbres. `phase` is in radians; each returns a value in [-1, 1].
    private func wave(_ phase: Double, instrument: Instrument) -> Double {
        switch instrument {
        case .theremin:
            // Pure sine -> the original MotionTune sound
            return sin(phase)

        case .piano:
            // Struck string: harmonic series with slow 1/n^1.1 rolloff (keeps
            // highs), plus a couple of inharmonic strike partials for attack.
            var out = 0.0
            for partial in Self.pianoPartials {
                out += partial.amp * sin(partial.ratio * phase)
            }
            return out

        case .violin:
            return violinWave(phase)
        }
    }

    /// Normalized additive spectra. Each list sums to 1.0, so a single voice
    /// peaks at exactly 1.0 and the master limiter handles the rest.
    private static let violinPartials: [(ratio: Double, amp: Double)] = {
        var coeffs: [(ratio: Double, amp: Double)] = []
        var sum = 0.0
        for n in 1...24 {
            let a = pow(Double(n), -1.3)
            coeffs.append((Double(n), a))
            sum += a
        }
        return coeffs.map { ($0.ratio, $0.amp / sum) }
    }()

    private static let pianoPartials: [(ratio: Double, amp: Double)] = {
        var coeffs: [(ratio: Double, amp: Double)] = []
        var sum = 0.0
        for n in 1...10 {
            let a = pow(Double(n), -1.1)
            coeffs.append((Double(n), a))
            sum += a
        }
        let extra: [(ratio: Double, amp: Double)] = [(2.4, 0.18), (3.2, 0.08)]
        sum += extra[0].amp + extra[1].amp
        return coeffs.map { ($0.ratio, $0.amp / sum) } + extra.map { ($0.ratio, $0.amp / sum) }
    }()

    /// Violin: bowed-string spectrum. Real bowed strings radiate many upper
    /// partials with a ~1/n^1.3 rolloff (vs a pluck's faster decay), which is
    /// exactly the "air" and definition the top end was missing.
    private func violinWave(_ p: Double) -> Double {
        var out = 0.0
        for partial in Self.violinPartials {
            out += partial.amp * sin(partial.ratio * p)
        }
        return out
    }

    private func finishPlayback() {
        if let file = exportFile {
            engine.mainMixerNode.removeTap(onBus: 0)
            exportFile = nil
            let url = exportURL
            exportURL = nil
            engine.stop()
            isPlaying = false
            padReleaseRequested = false
            padFade = 0
            padFadeTarget = 0
            padPendingChord = -1
            if let url {
                exportCompletion?(.success(url))
            }
            exportCompletion = nil
        } else {
            engine.stop()
            isPlaying = false
            padReleaseRequested = false
            padFade = 0
            padFadeTarget = 0
            padPendingChord = -1
        }
    }
}
