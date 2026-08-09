import SwiftUI
internal import CoreMotion

struct ContentView: View {
    @StateObject private var motionManager = MotionManager()
    @StateObject private var midiPlayer = MidiCurvePlayer()
    @State private var melodyInstrument: Instrument = .piano
    @State private var exportURL: URL?
    @State private var showExportSheet = false
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: motionManager.isTracking ? "waveform.path.ecg" : "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)

            Text("MotionTune")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(motionManager.isAvailable ? "Device motion available" : "Device motion unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
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

            VStack(alignment: .leading, spacing: 8) {
                // Sample Count Significance: Duration and resolution, not information content
                // More number of Samples != Richer signal
                Text("Samples recorded: \(motionManager.sampleCount)")
                Text("Attitude")
                    .font(.headline)
                Text("pitch: \(motionManager.attitude.pitch, specifier: "%.3f")")
                Text("Gravity")
                    .font(.headline)
                Text("y: \(motionManager.gravity.y, specifier: "%.3f")")
                Text("Angular Rotation Rate")
                    .font(.headline)
                Text("z: \(motionManager.rotationRate.z, specifier: "%.3f")")
            }
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            HStack(spacing: 16) {
                Button(action: motionManager.start) {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .disabled(motionManager.isTracking || !motionManager.isAvailable)

                Button(action: motionManager.stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .disabled(!motionManager.isTracking)
            }

            Menu {
                Button {
                    startPlayback(quantized: false)
                } label: {
                    Label("Play Recording", systemImage: "play.circle.fill")
                }

                Button {
                    midiPlayer.stop()
                } label: {
                    Label("Stop Playback", systemImage: "stop.circle.fill")
                }
                .disabled(!midiPlayer.isPlaying)

                Divider()

                ForEach(Instrument.allCases) { instrument in
                    Button {
                        midiPlayer.instrument = instrument
                        startPlayback(quantized: false)
                    } label: {
                        if midiPlayer.instrument == instrument {
                            Label(instrument.rawValue, systemImage: "checkmark")
                        } else {
                            Text(instrument.rawValue)
                        }
                    }
                }
            } label: {
                Label("Play Recording", systemImage: "music.note")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .opacity(motionManager.pitchBendSeries.isEmpty ? 0.4 : 1)

            VStack(spacing: 12) {
                Picker("Melody Instrument", selection: $melodyInstrument) {
                    ForEach([Instrument.piano, .violin]) { instrument in
                        Text(instrument.rawValue).tag(instrument)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(motionManager.pitchBendSeries.isEmpty)

                Button(action: playQuantized) {
                    Label("Play Recording (Melody)", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.teal, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .disabled(motionManager.pitchBendSeries.isEmpty || midiPlayer.isPlaying)

                Button(action: exportMelody) {
                    Label(isExporting ? "Exporting…" : "Export Melody", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .disabled(motionManager.pitchBendSeries.isEmpty || midiPlayer.isPlaying || isExporting)
            }
        }
        .padding()
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ActivityView(items: [exportURL])
            }
        }
    }

    private func startPlayback(quantized: Bool) {
        guard !motionManager.pitchBendSeries.isEmpty else { return }
        midiPlayer.loadSeries(
            pitchBend: motionManager.pitchBendSeries,
            cc11: motionManager.cc11Series,
            cc1: motionManager.cc1Series,
            roll: motionManager.rollSeries,
            quantized: quantized
        )
        midiPlayer.play()
    }

    private func playQuantized() {
        midiPlayer.instrument = melodyInstrument
        startPlayback(quantized: true)
    }

    private func exportMelody() {
        guard !motionManager.pitchBendSeries.isEmpty, !midiPlayer.isPlaying else { return }
        midiPlayer.instrument = melodyInstrument
        midiPlayer.loadSeries(
            pitchBend: motionManager.pitchBendSeries,
            cc11: motionManager.cc11Series,
            cc1: motionManager.cc1Series,
            roll: motionManager.rollSeries,
            quantized: true
        )
        let url = Self.exportFileURL()
        isExporting = true
        midiPlayer.playForExport(to: url) { result in
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
