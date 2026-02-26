import SwiftUI
import UniformTypeIdentifiers

/// A fájlválasztó képernyő: audio fájl kiválasztás + Start gomb
struct FilePickerView: View {

    @ObservedObject var viewModel: SessionViewModel
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App ikon / cím
            VStack(spacing: 8) {
                Image(systemName: "metronome")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("GTBiOS")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text("Drummer Timing Trainer")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

            Spacer()

            // Fájlválasztás
            VStack(spacing: 16) {
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text("Select Audio File")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.7))
                    .cornerRadius(12)
                }

                if !viewModel.selectedFileName.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(viewModel.selectedFileName)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 24)

            // Error message
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Mic permission warning
            if !viewModel.micPermissionGranted {
                HStack {
                    Image(systemName: "mic.slash.fill")
                        .foregroundColor(.orange)
                    Text("Mikrofon engedély szükséges")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Start gomb
            NavigationLink {
                LiveSessionView(viewModel: viewModel)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Session")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    viewModel.selectedFileURL != nil && viewModel.micPermissionGranted
                    ? Color.green.opacity(0.8)
                    : Color.gray.opacity(0.4)
                )
                .cornerRadius(12)
            }
            .disabled(viewModel.selectedFileURL == nil || !viewModel.micPermissionGranted)
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { url in
                viewModel.selectFile(url: url)
            }
        }
    }
}

// MARK: - Document Picker (UIViewControllerRepresentable)

/// UIDocumentPickerViewController wrapper SwiftUI-hoz (iOS 15 kompatibilis)
struct DocumentPickerView: UIViewControllerRepresentable {

    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .wav,
            .aiff,
            UTType(filenameExtension: "caf") ?? .audio
        ]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Preview

struct FilePickerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            FilePickerView(viewModel: SessionViewModel())
        }
    }
}
