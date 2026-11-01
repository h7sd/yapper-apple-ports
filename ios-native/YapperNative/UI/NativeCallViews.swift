import SwiftUI
import LiveKit

struct NativeCallButton: View {
    let store: NativeStore
    let channelID: String
    let title: String
    var serverID: String? = nil
    @Environment(NativeCallController.self) private var call

    var body: some View {
        Button {
            Task { await call.join(store: store, channelID: channelID, title: title, serverID: serverID, startNewCall: !store.activeCallChannels.contains(channelID)) }
        } label: {
            OriginalYapperIcon("phone").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Sprachanruf starten")
        .accessibilityIdentifier("native.call.start")
        .disabled(call.isConnecting)
    }
}

struct NativeCallBar: View {
    @Environment(NativeCallController.self) private var call
    var body: some View {
        if call.channelID != nil {
            HStack(spacing: 12) {
                Button { call.presented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(YapperPalette.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(call.title).font(OriginalYapper.font(14, weight: .bold)).lineLimit(1)
                            Text(call.status).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) { Task { await call.leave() } } label: {
                    Image(systemName: "phone.down.fill").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Anruf beenden")
            }
            .padding(.horizontal, 16)
            .background(YapperPalette.sidebar)
        }
    }
}

struct NativeCallView: View {
    @Environment(NativeCallController.self) private var call
    @Environment(\.dismiss) private var dismiss
    @State private var handRaised = false
    @State private var showingTools = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text(call.title).font(OriginalYapper.font(28, weight: .bold)).multilineTextAlignment(.center)
                        Text(call.status).foregroundStyle(YapperPalette.secondary)
                        if call.moderatorMuted {
                            Label("Mikrofon vorübergehend stummgeschaltet", systemImage: "mic.slash")
                                .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                        }
                        if call.encrypted {
                            Label("Ende-zu-Ende-verschlüsselt", systemImage: "lock.shield")
                                .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.success)
                        }
                    }
                    if call.isConnecting { ProgressView().padding() }
                    if let error = call.errorMessage { NativeErrorBanner(message: error, retry: { Task { await call.retry() } }) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(call.participants, id: \.sid) { participant in
                            NativeCallParticipant(participant: participant)
                                .frame(minHeight: 140)
                        }
                    }
                    if !call.safetyCode.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Sicherheitscode").font(OriginalYapper.font(16, weight: .semibold))
                            Text(call.safetyCode).font(OriginalYapper.font(15).monospaced()).textSelection(.enabled)
                            Text("Vergleicht diesen Code miteinander, um die Schlüssel dieses Gesprächs zu prüfen.")
                                .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if call.listener {
                        Button {
                            handRaised.toggle()
                            Task { await call.raiseHand(handRaised) }
                        } label: {
                            Label(handRaised ? "Hand senken" : "Hand heben", systemImage: "hand.raised")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                    if #unavailable(iOS 27) {
                        Text("Bildschirmteilen auf dieser iOS-Version erfasst die Yapper-App. Das Teilen anderer Apps benötigt eine Broadcast-Erweiterung.")
                            .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                    }
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(YapperPalette.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { controls }
                        VStack(spacing: 12) { controls }
                    }
                    Button(role: .destructive) {
                        Task { await call.leave(); dismiss() }
                    } label: {
                        Label("Anruf beenden", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(16)
                .background(YapperPalette.sidebar)
            }
            .navigationTitle("Sprachanruf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Anrufoptionen", systemImage: "slider.horizontal.3") { showingTools = true }
                        .disabled(call.room == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Minimieren") { dismiss() }.frame(minHeight: 44)
                }
            }
            .sheet(isPresented: $showingTools) {
                if let store = call.featureStore { NavigationStack { NativeVoiceToolsView(store: store) } }
            }
            .yapperNavigation()
        }
    }

    @ViewBuilder private var controls: some View {
        Button { Task { await call.setMicrophone(!call.microphoneOn) } } label: {
            Label(call.microphoneOn ? "Stummschalten" : "Mikrofon", systemImage: call.microphoneOn ? "mic.fill" : "mic.slash")
                .frame(minHeight: 44)
        }
        .disabled(call.listener || call.room == nil)
        Button { Task { await call.setDeafened(!call.deafened) } } label: {
            Label(call.deafened ? "Ton an" : "Ton aus", systemImage: call.deafened ? "speaker.slash" : "headphones")
                .frame(minHeight: 44)
        }
        .disabled(call.room == nil)
        Button { Task { await call.setCamera(!call.cameraOn) } } label: {
            Label("Kamera", systemImage: call.cameraOn ? "video.fill" : "video.slash")
                .frame(minHeight: 44)
        }
        .disabled(call.listener || call.room == nil)
        Button { Task { await call.setScreen(!call.screenOn) } } label: {
            Label("Bildschirm", systemImage: call.screenOn ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                .frame(minHeight: 44)
        }
        .disabled(call.listener || call.room == nil)
    }
}

private struct NativeCallParticipant: View {
    @ObservedObject var participant: Participant
    private var videos: [TrackPublication] {
        participant.trackPublications.values.filter { $0.track is VideoTrack }.sorted {
            let first = $0.source == .screenShareVideo ? 0 : $0.source == .camera ? 1 : 2
            let second = $1.source == .screenShareVideo ? 0 : $1.source == .camera ? 1 : 2
            return first == second ? $0.sid.stringValue < $1.sid.stringValue : first < second
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            if videos.isEmpty {
                NativeAvatar(name: participant.name ?? participant.identity?.stringValue ?? "Yapper", url: nil, size: 64)
                    .padding(.top, 12)
            }
            ForEach(videos, id: \.sid) { publication in
                NativeCallVideoPublication(publication: publication)
            }
            HStack(spacing: 6) {
                Text(participant.name ?? participant.identity?.stringValue ?? "Yapper").lineLimit(2)
                Image(systemName: participant.isMicrophoneEnabled() ? "mic.fill" : "mic.slash")
                    .foregroundStyle(YapperPalette.secondary)
            }
            .font(OriginalYapper.font(14))
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(YapperPalette.sidebar, in: .rect(cornerRadius: 12))
    }
}

private struct NativeCallVideoPublication: View {
    @ObservedObject var publication: TrackPublication
    private var screen: Bool { publication.source == .screenShareVideo }
    private var label: String { screen ? "Bildschirm" : publication.source == .camera ? "Kamera" : "Video" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: screen ? "rectangle.on.rectangle" : "video")
                .font(OriginalYapper.font(12, weight: .semibold))
                .foregroundStyle(YapperPalette.secondary)
            if !publication.isMuted, let track = publication.track as? VideoTrack {
                SwiftUIVideoView(track, layoutMode: .fit)
                    .frame(minHeight: 140, idealHeight: 220)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                Label(screen ? "Bildschirmübertragung pausiert" : "Video deaktiviert", systemImage: screen ? "pause.rectangle" : "video.slash")
                    .foregroundStyle(YapperPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .accessibilityIdentifier("native.call.video." + publication.sid.stringValue)
    }
}
