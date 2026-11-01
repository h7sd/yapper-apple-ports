import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct NativeAccountStandingView: View {
    let store: NativeStore
    @State private var standing: NativeAccountStanding?
    @State private var appeal: NativeJSON?
    @State private var message = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if isLoading { ProgressView("Kontostatus wird geladen …").frame(maxWidth: .infinity) }
            if let standing, standing.enabled {
                Section("Kontostatus") {
                    Label(standing.label, systemImage: standing.tier == "good" ? "checkmark.shield" : "exclamationmark.shield")
                        .font(OriginalYapper.font(16, weight: .semibold))
                    if let reason = standing.suspensionReason { Text(verbatim: reason) }
                    if let date = standing.suspendedUntil { LabeledContent("Gesperrt bis") { Text(date, format: .dateTime) } }
                    if let date = standing.improvesAt { LabeledContent("Verbessert sich am") { Text(date, format: .dateTime) } }
                }
                if !standing.warnings.isEmpty {
                    Section("Aktive Warnungen") {
                        ForEach(standing.warnings) { warning in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: warning.reason)
                                if let date = warning.at { Text(date, format: .dateTime).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                                if let date = warning.expires { Text("Zählt bis \(date.formatted(date: .abbreviated, time: .shortened))").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                            }
                        }
                    }
                }
            }
            if let appeal {
                let existing = appeal["appeal"]
                if existing.object != nil {
                    Section("Dein Widerspruch") {
                        Text(NativeSupportStatus.label(existing["status"].string ?? "pending")).font(OriginalYapper.font(16, weight: .semibold))
                        if let text = existing["message"].string { Text(verbatim: text).textSelection(.enabled) }
                        if let note = existing["staff_note"].string, !note.isEmpty { Text(verbatim: note) }
                    }
                }
                if appeal["open"].bool == true && existing["status"].string != "pending" {
                    Section("Widerspruch einreichen") {
                        TextField("Erkläre, warum die Entscheidung geprüft werden sollte.", text: $message, axis: .vertical).lineLimit(5...12)
                        Text("\(message.utf16.count)/1500").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        Button(isSaving ? "Wird gesendet …" : "Widerspruch senden") { Task { await submit() } }
                            .frame(minHeight: 44).disabled(isSaving || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.utf16.count > 1500)
                    }
                } else if existing.object == nil && !isLoading {
                    Text("Für dieses Konto ist zurzeit kein Widerspruch geöffnet.").foregroundStyle(YapperPalette.secondary)
                }
            }
        }
        .navigationTitle("Kontostatus")
        .task { await load() }
        .refreshable { await load() }
        .yapperNavigation()
    }
    private func load() async {
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { standing = try NativeAccountStanding(row: .object(["on": .bool(true), "tier": .string("good")])); appeal = .object(["open": .bool(false)]); return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in
                let standing = try await api.communityStanding(session: session)
                try Task.checkCancellation()
                let appeal = try await api.communityBanAppeal(session: session)
                return (standing, appeal)
            }
            standing = result.0; appeal = result.1
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func submit() async {
        guard !isSaving else { return }; isSaving = true; error = nil; defer { isSaving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.submitCommunityBanAppeal(message, session: session) }
            message = ""; await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeBugReportsView: View {
    let store: NativeStore
    let canEdit: Bool
    @State private var reports: [NativeBugReport] = []
    @State private var editing: NativeBugReport?
    @State private var creating = false
    @State private var removing: NativeBugReport?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if isLoading && reports.isEmpty { ProgressView("Fehlerberichte werden geladen …").frame(maxWidth: .infinity) }
            else if reports.isEmpty && error == nil { ContentUnavailableView("Noch keine Fehlerberichte", systemImage: "ladybug", description: Text("Beschreibe einen Fehler, damit das Yapper-Team ihn prüfen kann.")) }
            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: report.title).font(OriginalYapper.font(16, weight: .semibold))
                    Text(NativeSupportStatus.label(report.status)).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                    Text(verbatim: report.body).font(OriginalYapper.font(14)).textSelection(.enabled)
                    if let date = report.createdAt { Text(date, format: .dateTime.day().month().year()).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                    if canEdit && ["open", "confirmed"].contains(report.status) {
                        HStack {
                            Button("Bearbeiten") { editing = report }
                            Button("Zurückziehen", role: .destructive) { removing = report }
                        }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Fehlerberichte")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fehler melden", systemImage: "plus") { creating = true }.frame(minHeight: 44) } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating) { NavigationStack { NativeBugReportEditor(store: store, existing: nil) { Task { await load() } } } }
        .sheet(item: $editing) { report in NavigationStack { NativeBugReportEditor(store: store, existing: report) { Task { await load() } } } }
        .confirmationDialog("Fehlerbericht zurückziehen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let removing { Button("Zurückziehen", role: .destructive) { Task { await withdraw(removing) } } }
        }
        .yapperNavigation()
    }
    private func load() async {
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { reports = []; return }
            #endif
            reports = try await store.withAuthenticatedSession { api, session in try await api.communityBugReports(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func withdraw(_ report: NativeBugReport) async {
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.withdrawCommunityBugReport(id: report.id, session: session) }
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeBugReportEditor: View {
    let store: NativeStore
    let existing: NativeBugReport?
    let onSaved: @MainActor () -> Void
    @State private var title: String
    @State private var details: String
    @State private var severity: String
    @State private var images: [String]
    @State private var photos: [PhotosPickerItem] = []
    @State private var isSaving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: NativeStore, existing: NativeBugReport?, onSaved: @escaping @MainActor () -> Void) {
        self.store = store; self.existing = existing; self.onSaved = onSaved
        _title = State(initialValue: existing?.title ?? "")
        _details = State(initialValue: existing?.body ?? "")
        _severity = State(initialValue: existing?.severity ?? "normal")
        _images = State(initialValue: existing?.images ?? [])
    }

    var body: some View {
        let photoLabel = photos.isEmpty ? "Screenshots auswählen" : "\(photos.count) Screenshots ausgewählt"
        Form {
            Section("Fehler beschreiben") {
                TextField("Kurzer Titel", text: $title)
                TextField("Was hast du gemacht, was ist passiert und was hast du erwartet?", text: $details, axis: .vertical).lineLimit(5...14)
                Picker("Art", selection: $severity) {
                    Text("Fehler").tag("normal")
                    Text("Darstellung").tag("low")
                    Text("Sicherheit").tag("security")
                }
                Text("Titel: \(title.utf16.count)/120 · Beschreibung: \(details.utf16.count)/4000").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            }
            Section("Screenshots (maximal 4)") {
                ForEach(Array(images.enumerated()), id: \.offset) { index, _ in
                    HStack { Label("Bild \(index + 1)", systemImage: "photo"); Spacer(); Button("Entfernen", role: .destructive) { images.remove(at: index) }.frame(minHeight: 44) }
                }
                PhotosPicker(selection: $photos, maxSelectionCount: max(1, 4 - images.count), matching: .images) {
                    Label(photoLabel, systemImage: "photo.badge.plus")
                }
                .frame(minHeight: 44).disabled(images.count >= 4)
            }
            if let error { NativeErrorBanner(message: error) }
        }
        .navigationTitle(existing == nil ? "Fehler melden" : "Fehlerbericht bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(isSaving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Sendet …" : existing == nil ? "Senden" : "Speichern") { Task { await save() } }
                    .disabled(isSaving || !(5...120).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) || !(20...4000).contains(details.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) || images.count + photos.count > 4)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .yapperNavigation()
    }
    private func save() async {
        guard !isSaving else { return }; isSaving = true; error = nil; defer { isSaving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            while let photo = photos.first {
                let picked = try await NativeSupportImage.read(photo)
                let path = try await store.withAuthenticatedSession { api, session in try await api.uploadProofImage(data: picked.data, contentType: picked.type, session: session) }
                images.append(path); photos.removeFirst()
            }
            try await store.withAuthenticatedSession { api, session in try await api.saveCommunityBugReport(id: existing?.id, title: title, body: details, severity: severity, images: images, session: session) }
            onSaved(); dismiss()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeVerificationApplicationView: View {
    let store: NativeStore
    @State private var existing: NativeJSON?
    @State private var platform = "youtube"
    @State private var handle = ""
    @State private var link = ""
    @State private var note = ""
    @State private var photo: PhotosPickerItem?
    @State private var proofPath: String?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        let photoLabel = photo == nil ? "Nachweis auswählen (optional)" : "Nachweis ausgewählt"
        Form {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if isLoading { ProgressView("Antrag wird geladen …") }
            if let existing {
                Section("Dein letzter Antrag") {
                    Text(NativeSupportStatus.label(existing["status"].string ?? "pending")).font(OriginalYapper.font(16, weight: .semibold))
                    if let handle = existing["handle"].string { Text(verbatim: handle) }
                    if let note = existing["staff_note"].string, !note.isEmpty { Text(verbatim: note) }
                    if existing["status"].string == "needs_proof" {
                        Button("Nachweis hinzugefügt") { Task { await proofAdded(existing) } }.frame(minHeight: 44).disabled(isSaving)
                    }
                }
            }
            if existing?["status"].string != "pending" && existing?["status"].string != "needs_proof" && existing?["status"].string != "approved" {
                Section("Öffentliches Profil") {
                    Picker("Plattform", selection: $platform) {
                        Text("YouTube").tag("youtube"); Text("Twitch").tag("twitch"); Text("TikTok").tag("tiktok")
                        Text("Instagram").tag("instagram"); Text("X").tag("x"); Text("Andere").tag("other")
                    }
                    TextField("Name auf der Plattform", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("https://…", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Nachricht an das Team", text: $note, axis: .vertical).lineLimit(3...8)
                    PhotosPicker(selection: $photo, matching: .images) { Label(photoLabel, systemImage: "photo") }.frame(minHeight: 44)
                    Button(isSaving ? "Wird gesendet …" : "Verifizierung beantragen") { Task { await submit() } }
                        .frame(minHeight: 44).disabled(isSaving || handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !link.hasPrefix("https://"))
                }
            }
        }
        .navigationTitle("Verifizierung")
        .task { await load() }
        .disabled(isSaving)
        .yapperNavigation()
    }
    private func load() async {
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { existing = nil; return }
            #endif
            existing = try await store.withAuthenticatedSession { api, session in try await api.communityVerificationRequest(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func submit() async {
        guard !isSaving else { return }; isSaving = true; error = nil; defer { isSaving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            if let photo {
                let picked = try await NativeSupportImage.read(photo)
                proofPath = try await store.withAuthenticatedSession { api, session in try await api.uploadProofImage(data: picked.data, contentType: picked.type, session: session) }
                self.photo = nil
            }
            try await store.withAuthenticatedSession { api, session in try await api.submitCommunityVerification(platform: platform, handle: handle, link: link, note: note, proofPath: proofPath, session: session) }
            handle = ""; link = ""; note = ""; proofPath = nil; await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func proofAdded(_ existing: NativeJSON) async {
        guard let id = existing["id"].string, UUID(uuidString: id) != nil else { return }
        isSaving = true; error = nil; defer { isSaving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            _ = try await store.withAuthenticatedSession { api, session in try await api.rpc("verification_proof_added", arguments: ["rid": .string(id)], session: session) }
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeReportComposer: View {
    let store: NativeStore
    let target: NativeReportTarget
    @State private var reason: NativeReportReason = .other
    @State private var details = ""
    @State private var isSaving = false
    @State private var sent = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if sent { Label("Meldung gesendet", systemImage: "checkmark.circle") }
            else {
                Section("Meldung") {
                    Picker("Grund", selection: $reason) { ForEach(NativeReportReason.allCases) { Text($0.label).tag($0) } }
                    TextField("Beschreibe, was passiert ist.", text: $details, axis: .vertical).lineLimit(5...12)
                    Text("\(details.utf16.count)/4000").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
                if let error { NativeErrorBanner(message: error) }
                Button(isSaving ? "Wird gesendet …" : "Meldung senden") { Task { await submit() } }
                    .frame(minHeight: 44).disabled(isSaving || details.utf16.count > 4000)
            }
        }
        .navigationTitle("Melden")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(sent ? "Fertig" : "Abbrechen") { dismiss() }.disabled(isSaving) } }
        .interactiveDismissDisabled(isSaving)
        .yapperNavigation()
    }
    private func submit() async {
        guard !isSaving else { return }; isSaving = true; error = nil; defer { isSaving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.reportCommunityTarget(target, reason: reason, details: details, session: session) }
            details = ""; sent = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private enum NativeSupportImage {
    struct Picked: Sendable { let data: Data; let type: String }
    static func read(_ item: PhotosPickerItem) async throws -> Picked {
        guard let data = try await item.loadTransferable(type: Data.self), data.count <= 8 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), let sourceType = CGImageSourceGetType(source) else { throw NativeClientError.invalidResponse }
        if let type = UTType(sourceType as String)?.preferredMIMEType, ["image/png", "image/jpeg", "image/webp"].contains(type) { return Picked(data: data, type: type) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4_096]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.9) else { throw NativeClientError.invalidResponse }
        return Picked(data: jpeg, type: "image/jpeg")
    }
}

enum NativeSupportStatus {
    static func label(_ value: String) -> String {
        switch value {
        case "pending": "Wartet auf Prüfung"
        case "open": "Offen"
        case "confirmed": "Bestätigt"
        case "approved": "Genehmigt"
        case "rejected": "Abgelehnt"
        case "needs_proof": "Weiterer Nachweis erforderlich"
        case "fixed": "Behoben"
        case "duplicate": "Bereits gemeldet"
        default: value
        }
    }
}
