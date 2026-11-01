import Photos
import PhotosUI
import SwiftUI

/// The system Photos picker grants access only to the selected item; no library permission is needed.
struct NativeGalleryPicker: View {
    let onImport: @MainActor (NativeGalleryAttachment) -> Void
    let onFailure: @MainActor (any Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false

    var body: some View {
        NativeGalleryController(isImporting: $isImporting) { result in
            switch result {
            case .success(let attachment): onImport(attachment)
            case .failure(let error): onFailure(error)
            case nil: break
            }
            dismiss()
        }
        .accessibilityHidden(isImporting)
        .overlay {
            if isImporting {
                VStack(spacing: 16) {
                    ProgressView("Foto oder Video wird vorbereitet …")
                    Button("Abbrechen", role: .cancel) { dismiss() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("native.gallery.cancelImport")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(YapperPalette.background)
                .foregroundStyle(YapperPalette.text)
                .tint(YapperPalette.accent)
                .accessibilityIdentifier("native.gallery.importing")
            }
        }
    }
}

private struct NativeGalleryController: UIViewControllerRepresentable {
    @Binding var isImporting: Bool
    let onComplete: @MainActor (Result<NativeGalleryAttachment, any Error>?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        controller.view.accessibilityIdentifier = "native.gallery.picker"
        controller.view.tintColor = UIColor(YapperPalette.accent)
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    static func dismantleUIViewController(_ controller: PHPickerViewController, coordinator: Coordinator) { coordinator.cancel() }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: NativeGalleryController
        private var progress: Progress?
        private var importTask: Task<Void, Never>?
        private var finished = false

        init(parent: NativeGalleryController) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished, importTask == nil, progress == nil else { return }
            guard let result = results.first else { finish(nil); return }
            let provider = result.itemProvider
            guard let representation = NativeGalleryImport.representation(for: provider.registeredTypeIdentifiers, prefersStill: provider.canLoadObject(ofClass: PHLivePhoto.self)) else {
                finish(.failure(NativeClientError.api(status: 400, message: "Wähle ein Foto oder ein unterstütztes Video aus.")))
                return
            }
            parent.isImporting = true
            let suggestedName = provider.suggestedName
            progress = provider.loadFileRepresentation(forTypeIdentifier: representation.typeIdentifier) { [weak self] url, error in
                let copied: Result<NativeGalleryFile, any Error>
                if let error { copied = .failure(error) }
                else if let url {
                    copied = Result { try NativeGalleryImport.copyFile(from: url, representation: representation, suggestedFilename: suggestedName) }
                } else {
                    copied = .failure(NativeClientError.api(status: 400, message: "Das Foto oder Video ist derzeit nicht verfügbar. Lade es aus iCloud und versuche es erneut."))
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.finished else {
                        if case .success(let file) = copied { file.remove() }
                        return
                    }
                    self.importCopy(copied)
                }
            }
        }

        private func importCopy(_ result: Result<NativeGalleryFile, any Error>) {
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let file):
                importTask = Task { [weak self] in
                    do {
                        let attachment = try await NativeGalleryImport.attachment(from: file)
                        guard let self, !self.finished else { return }
                        self.finish(.success(attachment))
                    } catch is CancellationError {} catch {
                        guard let self, !self.finished else { return }
                        self.finish(.failure(error))
                    }
                }
            }
        }

        private func finish(_ result: Result<NativeGalleryAttachment, any Error>?) {
            guard !finished else { return }
            finished = true
            parent.isImporting = false
            parent.onComplete(result)
        }

        func cancel() {
            finished = true
            progress?.cancel()
            importTask?.cancel()
        }
    }
}
