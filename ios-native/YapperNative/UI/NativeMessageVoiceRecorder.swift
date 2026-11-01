import SwiftUI
import AVFoundation
import Observation

nonisolated struct NativeVoiceRecording: Sendable {
    let data: Data
    let duration: Double
    let waveform: [Double]
    let filename: String
}

@MainActor @Observable private final class NativeVoiceRecorder {
    private(set) var recording = false
    private(set) var requestingPermission = false
    private(set) var duration: Double = 0
    private(set) var waveform: [Double] = []
    var error: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var ownsAudioSession = false

    func start() async {
        guard active, !recording, !requestingPermission else { return }
        requestingPermission = true; error = nil
        let allowed = await AVAudioApplication.requestRecordPermission()
        requestingPermission = false
        guard active else { return }
        guard allowed else { error = "Erlaube den Mikrofonzugriff in den iPhone-Einstellungen, um eine Sprachnachricht aufzunehmen."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            ownsAudioSession = true
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-message-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: 300) else { throw NativeClientError.invalidResponse }
            self.recorder = recorder; fileURL = file; recording = true; duration = 0; waveform = []
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.active, let recorder = self.recorder else { return }
                    if !recorder.isRecording { self.recording = false; return }
                    self.duration = recorder.currentTime
                    recorder.updateMeters()
                    self.waveform.append(min(1, max(0.02, pow(10, Double(recorder.averagePower(forChannel: 0)) / 20))))
                }
            }
        } catch { self.error = error.localizedDescription; cleanup() }
    }

    func stop() {
        if let recorder, recorder.isRecording { duration = recorder.currentTime; recorder.stop() }
        timer?.cancel(); timer = nil; recording = false
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    func result() throws -> NativeVoiceRecording {
        stop()
        guard let fileURL, duration > 0.2, duration <= 305 else { throw NativeClientError.api(status: 400, message: "Die Aufnahme ist zu kurz. Nimm die Nachricht erneut auf.") }
        let data = try Data(contentsOf: fileURL)
        try NativeMediaUploadPolicy.validate(bucket: "attachments", bytes: data.count, contentType: "audio/mp4")
        let stride = max(1, waveform.count / 50)
        let bars = Swift.stride(from: 0, to: waveform.count, by: stride).map { waveform[$0] }
        return NativeVoiceRecording(data: data, duration: duration, waveform: Array(bars.prefix(50)), filename: fileURL.lastPathComponent)
    }

    func cleanup() {
        stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil; recorder = nil
    }

    func cancel() { active = false; cleanup() }
}

struct NativeVoiceRecorderSheet: View {
    let finished: @MainActor (NativeVoiceRecording) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(NativeCallController.self) private var call
    @State private var recorder = NativeVoiceRecorder()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: recorder.recording ? "waveform" : "mic.fill")
                    .font(.system(size: 56)).foregroundStyle(recorder.recording ? YapperPalette.danger : YapperPalette.accent)
                    .accessibilityHidden(true)
                Text(Duration.seconds(recorder.duration).formatted(.time(pattern: .minuteSecond))).font(OriginalYapper.font(32).monospacedDigit())
                Text(recorder.recording ? "Aufnahme läuft" : "Bis zu 5 Minuten").foregroundStyle(YapperPalette.secondary)
                if call.channelID != nil { Text("Beende zuerst deinen laufenden Anruf, um eine Sprachnachricht aufzunehmen.").multilineTextAlignment(.center).foregroundStyle(YapperPalette.secondary) }
                if let error = recorder.error { Text(error).foregroundStyle(YapperPalette.danger).multilineTextAlignment(.center) }
                if recorder.requestingPermission { ProgressView() }
                Button {
                    if recorder.recording { recorder.stop() }
                    else { Task { await recorder.start() } }
                } label: {
                    Label(recorder.recording ? "Aufnahme stoppen" : "Aufnehmen", systemImage: recorder.recording ? "stop.fill" : "record.circle")
                        .frame(minWidth: 180, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.requestingPermission || call.channelID != nil)
                if !recorder.recording && recorder.duration > 0 {
                    Button("Aufnahme übernehmen") {
                        do { finished(try recorder.result()); dismiss() }
                        catch { recorder.error = error.localizedDescription }
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                }
                Spacer(minLength: 0)
            }
            .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle("Sprachnachricht").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { recorder.cancel(); dismiss() } } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { recorder.stop() } }
            .onDisappear { recorder.cancel() }
            .yapperNavigation()
        }
    }
}

struct NativeVoiceMessagePlayer: View {
    let url: URL
    let seconds: Double
    let wave: String?
    @State private var player: AVPlayer?
    @State private var wantsPlayback = false
    @State private var seeking = false
    @State private var seekPosition = 0.0
    @Environment(NativeCallController.self) private var call

    private var levels: [Double] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let values = Array(wave ?? "").map { character in Double(alphabet.firstIndex(of: character) ?? 0) / 63 }
        return (0..<40).map { index in values.isEmpty ? 0.3 : values[min(values.count - 1, index * values.count / 40)] }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let time = player?.currentTime().seconds ?? 0
            let current = max(0, min(seconds, time.isFinite ? time : 0))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        if player == nil { player = AVPlayer(url: url) }
                        if wantsPlayback && current < seconds - 0.1 { player?.pause(); wantsPlayback = false }
                        else {
                            if current >= seconds - 0.1 { player?.seek(to: .zero) }
                            if call.channelID == nil { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio) }
                            player?.play(); wantsPlayback = true
                        }
                    } label: { Image(systemName: wantsPlayback && current < seconds ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                        .buttonStyle(.borderedProminent).accessibilityLabel(wantsPlayback && current < seconds - 0.1 ? "Sprachnachricht pausieren" : "Sprachnachricht abspielen")
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(levels.enumerated()), id: \.offset) { index, value in
                            Capsule().fill(Double(index) / 40 <= current / max(0.1, seconds) ? YapperPalette.accent : YapperPalette.secondary.opacity(0.45))
                                .frame(maxWidth: .infinity).frame(height: max(4, 32 * value))
                        }
                    }
                    .frame(height: 34).accessibilityHidden(true)
                    Text(Duration.seconds(current > 0 ? current : seconds).formatted(.time(pattern: .minuteSecond)))
                        .font(OriginalYapper.font(12).monospacedDigit()).foregroundStyle(YapperPalette.secondary)
                }
                Slider(value: Binding(get: { seeking ? seekPosition : current }, set: { seekPosition = $0 }), in: 0...max(0.1, seconds)) { editing in
                    if editing { seekPosition = current; seeking = true }
                    else {
                        if player == nil { player = AVPlayer(url: url) }
                        player?.seek(to: CMTime(seconds: seekPosition, preferredTimescale: 600)); seeking = false
                    }
                }
                .accessibilityLabel("Wiedergabeposition")
                if player?.status == .failed {
                    Button("Audio erneut laden") { player?.pause(); player = nil; wantsPlayback = false }.font(OriginalYapper.font(12)).frame(minHeight: 44)
                }
            }
            .frame(maxWidth: 380)
        }
        .onDisappear { player?.pause(); player = nil; wantsPlayback = false }
    }
}
