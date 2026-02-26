import SwiftUI

/// A fő "élő" képernyő: hisztogramok + sliderek + stop gomb
struct LiveSessionView: View {

    @ObservedObject var viewModel: SessionViewModel
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 16) {

            // MARK: - Status bar
            statusBar

            // MARK: - FOOT hisztogram
            TimingBarView(
                label: "FOOT (1 & 3)",
                histogram: viewModel.footHistogram,
                lastBin: viewModel.lastFootBin,
                borderThick: viewModel.footBorderThick
            )

            // MARK: - HAND hisztogram
            TimingBarView(
                label: "HAND (2 & 4)",
                histogram: viewModel.handHistogram,
                lastBin: viewModel.lastHandBin,
                borderThick: viewModel.handBorderThick
            )

            Spacer()

            // MARK: - Sliderek
            slidersSection

            // MARK: - Stop gomb
            Button {
                viewModel.stop()
                presentationMode.wrappedValue.dismiss()
            } label: {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red.opacity(0.8))
                .cornerRadius(12)
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            if viewModel.isSessionActive {
                viewModel.stop()
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            // Állapot jelző
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            Text(viewModel.statusText)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)
        .padding(.horizontal, 16)
    }

    private var statusColor: Color {
        switch viewModel.appState {
        case .idle: return .gray
        case .countIn: return .orange
        case .active: return .green
        }
    }

    // MARK: - Sliders section

    private var slidersSection: some View {
        VStack(spacing: 12) {
            // Click Threshold
            sliderRow(
                label: "Click Threshold",
                value: Binding(
                    get: { Double(viewModel.clickThreshold) },
                    set: { viewModel.clickThreshold = Float($0) }
                ),
                range: 0.01...1.0,
                displayValue: String(format: "%.2f", viewModel.clickThreshold)
            )

            // Mic Threshold
            sliderRow(
                label: "Mic Threshold",
                value: Binding(
                    get: { Double(viewModel.micThreshold) },
                    set: { viewModel.micThreshold = Float($0) }
                ),
                range: 0.01...1.0,
                displayValue: String(format: "%.2f", viewModel.micThreshold)
            )

            // Latency Offset
            sliderRow(
                label: "Latency Offset",
                value: $viewModel.latencyOffsetMs,
                range: -100.0...100.0,
                displayValue: String(format: "%.1f ms", viewModel.latencyOffsetMs)
            )
        }
        .padding(.horizontal, 16)
    }

    /// Egy slider sor: label + érték + slider
    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, displayValue: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Text(displayValue)
                    .font(.caption)
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .accentColor(.green)
        }
    }
}

// MARK: - Preview

struct LiveSessionView_Previews: PreviewProvider {
    static var previews: some View {
        LiveSessionView(viewModel: SessionViewModel())
    }
}
