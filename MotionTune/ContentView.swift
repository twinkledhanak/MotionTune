import SwiftUI
internal import CoreMotion

/// Central dark-UI palette: warm charcoal base, a cool blue playhead accent,
/// and one warm red CTA. Everything else stays muted.
private enum MTPalette {
    static let bg = Color(red: 0.11, green: 0.10, blue: 0.09)            // warm charcoal
    static let accentBlue = Color(red: 0.25, green: 0.55, blue: 1.0)     // playhead / links
    static let ctaRed = Color(red: 0.88, green: 0.25, blue: 0.22)        // single warm CTA
    static let rawGreen = Color(red: 0.30, green: 0.80, blue: 0.50)      // play raw
    static let pianoGreen = Color(red: 0.35, green: 0.65, blue: 0.55)    // play melody (piano)
    static let violinGreen = Color(red: 0.50, green: 0.78, blue: 0.35)   // play melody (violin)
    static let deleteGray = Color(red: 0.42, green: 0.42, blue: 0.46)    // delete
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.10)
}

struct ContentView: View {
    @StateObject private var motionManager = MotionManager()
    @StateObject private var midiPlayer = MidiCurvePlayer()
    @StateObject private var zeticModel = ZeticModelManager()
    @State private var exportURL: URL?
    @State private var showExportSheet = false
    @State private var isExporting = false

    var body: some View {
        ZStack {
            MTPalette.bg.ignoresSafeArea()

            // Soft ambient glow behind the waveform, tinted blue to echo
            // the playhead accent.
            Circle()
                .fill(MTPalette.accentBlue.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(y: -40)

            GeometryReader { geo in
                // Fit the wave to ~60% of the screen while guaranteeing the
                // title and controls below stay visible (no overflow).
                let waveHeight = max(200.0, min(geo.size.height * 0.6, geo.size.height - 500.0))

                VStack(spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)

                    Text("MotionTune")
                        .font(.system(size: 32, weight: .semibold, design: .serif))
                        .foregroundColor(.white)

                    Text("Live")
                        .font(.caption)
                        .foregroundColor(.white)

//            Text(motionManager.isAvailable ? "Device motion available" : "Device motion unavailable")
//                .font(.subheadline)
//                .foregroundStyle(.secondary)
            
            /**
                
             Only these below axes matter when we want to capture the right music shape
             Primary axis: attitude.pitch → pitch bend curve Smooth up/down glides
             
             Secondary axis: gravity.y → expression (CC11) Natural volume swells
             
             Optional axis: rotationRate.z → modulation (CC1) Adds vibrato when user rotates faster
             
             Mapping for Sensor Data <=> Raw MIDI curve [Differs on basis of Instrument behavior]
             Eg: Classic [Our choice for now!!]
             attitude.pitch → MIDI Pitch Bend (For glide)
             gravity.y → MIDI CC11 (For Expression, Dynamics)
             rotationRate.z → MIDI CC1 (For Modulation, Vibrato)
             
             Eg: Close to MPE-style timbre control
             PitchNorm → Pitch Bend
             GravityNorm → CC74 (timbre)
             RotationNorm → Pressure
             
             */

                SensorGraphView(
                    motionManager: motionManager,
                    height: waveHeight,
                    playbackProgress: midiPlayer.isPlaying ? midiPlayer.progress : nil
                )
                    .padding(.top, 28)

                Text(recordingTimeString)
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.top, -24)

            HStack(spacing: 28) {
                Button(action: toggleRecording) {
                    ElevatedCircleButton(
                        icon: motionManager.isTracking ? "stop.fill" : "mic.fill",
                        label: motionManager.isTracking ? "Stop" : "Record",
                        color: motionManager.isTracking ? MTPalette.ctaRed : MTPalette.accentBlue
                    )
                }
                .disabled(!motionManager.isAvailable)

                Button(action: resetRecording) {
                    ElevatedCircleButton(icon: "trash", label: "Delete", color: MTPalette.deleteGray)
                }
                .disabled(motionManager.pitchBendSeries.isEmpty)
            }
            .padding(.top, 8)

            HStack(spacing: 24) {
                Button {
                    startPlayback(quantized: false)
                } label: {
                    ElevatedCircleButton(
                        icon: "waveform", label: "Raw", color: MTPalette.rawGreen,
                        progress: midiPlayer.isPlaying && !midiPlayer.isMelodyPlayback ? midiPlayer.progress : nil
                    )
                }
                .disabled(motionManager.pitchBendSeries.isEmpty || midiPlayer.isPlaying)

                Button {
                    playMelody(instrument: .piano)
                } label: {
                    ElevatedCircleButton(
                        icon: "music.note", label: "Piano", color: MTPalette.pianoGreen,
                        progress: midiPlayer.isPlaying && midiPlayer.isMelodyPlayback && midiPlayer.instrument == .piano ? midiPlayer.progress : nil
                    )
                }
                .disabled(motionManager.pitchBendSeries.isEmpty || midiPlayer.isPlaying)

                Button {
                    playMelody(instrument: .violin)
                } label: {
                    ElevatedCircleButton(
                        icon: "music.quarternote.3", label: "Violin", color: MTPalette.violinGreen,
                        progress: midiPlayer.isPlaying && midiPlayer.isMelodyPlayback && midiPlayer.instrument == .violin ? midiPlayer.progress : nil
                    )
                }
                .disabled(motionManager.pitchBendSeries.isEmpty || midiPlayer.isPlaying)
            }
            .padding(.top, 16)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding()
        }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            Menu {
                Button {
                    exportMelody(as: .piano)
                } label: {
                    Label("Share Piano Tune", systemImage: "music.note")
                }
                Button {
                    exportMelody(as: .violin)
                } label: {
                    Label("Share Violin Tune", systemImage: "music.quarternote.3")
                }
            } label: {
                if isExporting {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(MTPalette.surface, in: Circle())
                }
            }
            .disabled(motionManager.pitchBendSeries.isEmpty || midiPlayer.isPlaying || isExporting)
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .task { await zeticModel.load() }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ActivityView(items: [exportURL])
            }
        }
    }

    private var recordingTimeString: String {
        let seconds = motionManager.sampleCount / 60
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func toggleRecording() {
        if motionManager.isTracking {
            motionManager.stop()
            zeticModel.runInference(cc11: motionManager.cc11Series)
        } else {
            motionManager.start()
        }
    }

    private func resetRecording() {
        midiPlayer.stop()
        motionManager.reset()
    }

    private func startPlayback(quantized: Bool) {
        guard !motionManager.pitchBendSeries.isEmpty else { return }
        let cc11 = quantized && !zeticModel.refinedCC11.isEmpty
            ? zeticModel.refinedCC11
            : motionManager.cc11Series
        midiPlayer.loadSeries(
            pitchBend: motionManager.pitchBendSeries,
            cc11: cc11,
            cc1: motionManager.cc1Series,
            roll: motionManager.rollSeries,
            quantized: quantized
        )
        midiPlayer.play()
    }

    private func playMelody(instrument: Instrument) {
        midiPlayer.instrument = instrument
        startPlayback(quantized: true)
    }

    private func exportMelody(as instrument: Instrument) {
        guard !motionManager.pitchBendSeries.isEmpty, !midiPlayer.isPlaying else { return }
        midiPlayer.instrument = instrument
        let cc11 = !zeticModel.refinedCC11.isEmpty
            ? zeticModel.refinedCC11
            : motionManager.cc11Series
        midiPlayer.loadSeries(
            pitchBend: motionManager.pitchBendSeries,
            cc11: cc11,
            cc1: motionManager.cc1Series,
            roll: motionManager.rollSeries,
            quantized: true
        )
        let url = Self.exportFileURL()
        isExporting = true
        midiPlayer.exportToFile(to: url) { result in
            DispatchQueue.main.async {
                self.isExporting = false
                if case .success(let url) = result {
                    self.exportURL = url
                    self.showExportSheet = true
                }
            }
        }
    }

    private static func exportFileURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("MotionTune-Melody-\(stamp).wav")
    }
}

struct ElevatedCircleButton: View {
    let icon: String
    let label: String
    let color: Color
    var isSelected: Bool = false
    var progress: Double? = nil

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [color.opacity(0.95), color.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Circle()
                    .stroke(LinearGradient(
                        colors: [.white.opacity(0.35), .clear],
                        startPoint: .top, endPoint: .center
                    ), lineWidth: 1.2)
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .font(.system(size: 26, weight: .medium))
                // Progress ring: a white arc that fills clockwise with playback.
                if let progress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 66, height: 66)
                }
            }
            .frame(width: 80, height: 80)
            .shadow(color: color.opacity(isSelected ? 0.5 : 0.25), radius: isSelected ? 16 : 10, y: 8)

            Text(label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}

/// Voice-Memos-style waveform: a row of vertical bars. While recording the
/// bars scroll left (each bar is one short window of CC11 expression energy).
/// During playback the full recording is shown, played bars are highlighted in
/// blue, upcoming bars are dimmed, and a playhead line sweeps across.
struct SensorGraphView: View {
    @ObservedObject var motionManager: MotionManager
    var height: CGFloat
    var playbackProgress: Double? = nil

    private let bars = 72
    private let samplesPerBar = 4
    private let ccRange = 0.0...127.0

    var body: some View {
        Canvas { context, size in
            drawCentreLine(&context, size: size)
            drawBars(&context, size: size)
        }
        .frame(height: height)
        .padding(.horizontal, 20)
    }

    private func drawCentreLine(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(path, with: .color(MTPalette.accentBlue.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
    }

    /// Bars grow up and down from the centre line, like a voice-memo waveform.
    /// Bar height = peak CC11 amplitude over its time bin. While recording the
    /// newest samples are shown on the right; during playback the whole take is
    /// pooled into the same number of bars, played ones in blue, the rest dim.
    private func drawBars(_ context: inout GraphicsContext, size: CGSize) {
        let cc = motionManager.cc11Series
        guard !cc.isEmpty else { return }

        let isPlayback = playbackProgress != nil
        let halfHeight = size.height / 2 - 6
        let barWidth = size.width / CGFloat(bars)
        let gap: CGFloat = 4

        for b in 0..<bars {
            let sampleStart: Int
            let sampleEnd: Int
            if isPlayback {
                let s0 = Int(Double(b) * Double(cc.count) / Double(bars))
                let s1 = Int(Double(b + 1) * Double(cc.count) / Double(bars)) - 1
                sampleStart = max(0, s0)
                sampleEnd = min(cc.count - 1, s1)
            } else {
                // Rightmost bar (b = bars-1) covers the newest samples.
                let last = cc.count - 1
                sampleEnd = last - (bars - 1 - b) * samplesPerBar
                sampleStart = max(0, sampleEnd - samplesPerBar + 1)
            }
            guard sampleStart <= sampleEnd else { continue }

            var peak = 0.0
            for s in sampleStart...sampleEnd {
                peak = max(peak, Double(cc[s]))
            }
            let norm = (peak - ccRange.lowerBound) / (ccRange.upperBound - ccRange.lowerBound)
            let height = max(3.0, CGFloat(norm) * halfHeight)
            let x = CGFloat(b) * barWidth + gap / 2
            let rect = CGRect(x: x, y: size.height / 2 - height / 2,
                              width: barWidth - gap, height: height)
            let bar = Path(roundedRect: rect, cornerRadius: (barWidth - gap) / 2)

            if let progress = playbackProgress {
                if Double(b + 1) / Double(bars) <= progress {
                    context.fill(bar, with: .color(MTPalette.accentBlue.opacity(0.9)))
                } else {
                    context.fill(bar, with: .color(.white))
                }
            } else {
                context.fill(bar, with: .color(.white))
            }
        }
    }
}
