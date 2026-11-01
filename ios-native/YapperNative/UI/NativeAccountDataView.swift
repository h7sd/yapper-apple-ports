import SwiftUI
import UniformTypeIdentifiers

struct NativeAccountDataView: View {
    let store: NativeStore
    @State private var password = ""
    @State private var confirmDeletion = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var export: NativeAccountExport?
    @State private var exporting = false
    @State private var document = NativeAccountExportDocument(data: Data())
    @State private var operation: Task<Void, Never>?

    private var fixtures: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }

    var body: some View {
        Form {
            if let errorMessage { Section { NativeErrorBanner(message: errorMessage) } }
            if fixtures { Section { Text("Anonyme Testdaten. Export und Kontolöschung sind in dieser Ansicht deaktiviert.").foregroundStyle(.secondary) } }
            if store.capabilities.flagOn("data_export", userID: store.user?.id) {
                Section {
                    Button { download() } label: { Label("Meine Daten anfordern", systemImage: "square.and.arrow.down") }
                        .disabled(busy || fixtures)
                    if let export {
                        if !export.complete {
                            Text("Dieser Export enthält nicht alle Daten. Die Datei beschreibt die fehlenden Bereiche unter „sections“.")
                                .foregroundStyle(.orange)
                            if !export.cutShort.isEmpty { Text("Gekürzt: " + export.cutShort.joined(separator: ", ")) }
                            if !export.couldNotLoad.isEmpty { Text("Nicht geladen: " + export.couldNotLoad.joined(separator: ", ")) }
                        }
                        Button("JSON-Datei sichern") { document = NativeAccountExportDocument(data: export.data); exporting = true }
                    }
                } header: { Text("Datenexport") } footer: { Text("Der Server erstellt eine Kopie deiner Kontodaten. Du bestimmst beim Sichern den Speicherort.") }
            }
            Section {
                SecureField("Aktuelles Passwort", text: $password)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .disabled(busy || fixtures)
                Button("Konto dauerhaft löschen", role: .destructive) { confirmDeletion = true }
                    .disabled(password.isEmpty || busy || fixtures)
            } header: { Text("Konto löschen") } footer: { Text("Löscht dein Yapper-Konto und entfernt die damit verknüpften Medien. Dieser Schritt kann nicht rückgängig gemacht werden.") }
            if busy { Section { ProgressView("Anfrage wird verarbeitet …") } }
        }
        .navigationTitle("Meine Daten & Konto")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Yapper-Konto dauerhaft löschen?", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("Mein Konto dauerhaft löschen", role: .destructive) { deleteAccount() }
            Button("Abbrechen", role: .cancel) { }
        } message: { Text("Dein Konto, deine Mitgliedschaften und deine Medien werden gelöscht. Du wirst anschließend abgemeldet.") }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "yapper-data") { result in
            if case let .failure(error) = result { errorMessage = error.localizedDescription }
            document = NativeAccountExportDocument(data: Data())
        }
        .onDisappear { clear() }
        .onChange(of: store.authState) { _, state in if state != .signedIn { clear() } }
        .onChange(of: store.user?.id) { _, _ in clear() }
    }

    private func download() {
        guard !busy, !fixtures else { return }
        busy = true; errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                let value = try await store.withAuthenticatedSession { api, session in
                    try await NativeAccountDataService(api: api).export(session: session)
                }
                export = value
                document = NativeAccountExportDocument(data: value.data)
                exporting = true
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }

    private func deleteAccount() {
        guard !busy, !fixtures, !password.isEmpty else { return }
        let submittedPassword = password
        let gdpr = store.capabilities.flagOn("gdpr_delete", userID: store.user?.id)
        password = ""; busy = true; errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                try await store.withAuthenticatedSession { api, session in
                    try await NativeAccountDataService(api: api).deleteAccount(password: submittedPassword, gdprDelete: gdpr, session: session)
                }
                store.signOut()
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }

    private func clear() {
        operation?.cancel(); operation = nil
        password = ""; export = nil; document = NativeAccountExportDocument(data: Data())
    }
}

private struct NativeAccountExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
