import SwiftUI
import AVFoundation

/// A fő ViewModel — összeköti az audio engine-t, timing engine-t és a SwiftUI View-kat.
///
/// Adatfolyam:
/// 1. `selectFile()` → `AudioEngineManager.loadFile()` → pre-extracted click + R channel
/// 2. `start()` → engine setup → play → origin callback → timing engine grid felépítés
/// 3. Player tick → count-in progress frissítés
/// 4. Mic onset → `TimingEngine.handleMicHit()` → hisztogram frissítés → UI update
@MainActor
final class SessionViewModel: ObservableObject {

    // MARK: - Published state (UI binding)

    @Published var appState: AppState = .idle
    @Published var footHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
    @Published var handHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
    @Published var lastFootBin: Int? = nil
    @Published var lastHandBin: Int? = nil
    @Published var footBorderThick: Bool = false
    @Published var handBorderThick: Bool = false

    @Published var clickThreshold: Float = 0.15 {
        didSet { audioEngine.clickThreshold = clickThreshold }
    }
    @Published var micThreshold: Float = 0.1 {
        didSet { audioEngine.micDetector.threshold = micThreshold }
    }
    @Published var latencyOffsetMs: Double = 0.0 {
        didSet { timingEngine.latencyOffsetMs = latencyOffsetMs }
    }

    @Published var selectedFileURL: URL? = nil
    @Published var selectedFileName: String = ""
    @Published var errorMessage: String? = nil
    @Published var micPermissionGranted: Bool = false

    // MARK: - Private

    private let audioEngine = AudioEngineManager()
    private let timingEngine = TimingEngine()

    // MARK: - Init

    init() {
        setupCallbacks()
        checkMicPermission()
    }

    // MARK: - Mic permission

    private func checkMicPermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            micPermissionGranted = true
        case .denied:
            micPermissionGranted = false
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    self?.micPermissionGranted = granted
                }
            }
        @unknown default:
            micPermissionGranted = false
        }
    }

    // MARK: - Callbacks setup

    private func setupCallbacks() {
        // Mic onset → timing engine (hit-driven matching, azonnali kiértékelés)
        audioEngine.micDetector.onOnset = { [weak self] hostTimeNs in
            guard let self = self else { return }
            self.timingEngine.handleMicHit(hostTimeNs: hostTimeNs)
        }

        // Playback origin → timing engine (click pozíciók → abszolút hostTime)
        audioEngine.onOriginCaptured = { [weak self] originHostTimeNs in
            guard let self = self else { return }
            self.timingEngine.setPlaybackOrigin(hostTimeNs: originHostTimeNs)
        }

        // Player tick → count-in progress tracking
        audioEngine.onPlayerTick = { [weak self] currentHostTimeNs in
            guard let self = self else { return }
            self.timingEngine.tick(currentHostTimeNs: currentHostTimeNs)
        }

        // Timing engine state change → UI
        timingEngine.onStateChanged = { [weak self] newState in
            Task { @MainActor in
                self?.appState = newState
            }
        }

        // Timing event → UI update (hisztogram, marker, keret)
        timingEngine.onTimingEvent = { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                self.footHistogram = self.timingEngine.footHistogram
                self.handHistogram = self.timingEngine.handHistogram
                self.lastFootBin = self.timingEngine.lastFootBin
                self.lastHandBin = self.timingEngine.lastHandBin
                self.footBorderThick = self.timingEngine.footBorderThick
                self.handBorderThick = self.timingEngine.handBorderThick
            }
        }

        // Playback finished
        audioEngine.onPlaybackFinished = { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackFinished()
            }
        }
    }

    // MARK: - File selection

    /// Fájl kiválasztva a document picker-ből
    func selectFile(url: URL) {
        do {
            audioEngine.clickThreshold = clickThreshold
            try audioEngine.loadFile(url: url)
            selectedFileURL = url
            selectedFileName = url.lastPathComponent

            let clickCount = audioEngine.clickOnsetSamples.count
            if clickCount < TimingEngine.countInClicks {
                errorMessage = "Figyelem: csak \(clickCount) click-et találtam a fájlban (min. \(TimingEngine.countInClicks) kell a count-in-hez). Próbáld állítani a Click Threshold-ot."
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
            selectedFileURL = nil
            selectedFileName = ""
        }
    }

    // MARK: - Playback control

    func start() {
        guard selectedFileURL != nil else {
            errorMessage = "Nincs kiválasztott fájl."
            return
        }
        guard micPermissionGranted else {
            errorMessage = "Mikrofon engedély szükséges."
            checkMicPermission()
            return
        }

        do {
            // Audio session + engine setup
            try audioEngine.configureAudioSession()
            try audioEngine.setupEngine()

            // Timing engine beállítás: click pozíciók átadása
            timingEngine.configure(
                clickOnsetSamples: audioEngine.clickOnsetSamples,
                sampleRate: audioEngine.sampleRate
            )
            timingEngine.latencyOffsetMs = latencyOffsetMs
            timingEngine.start()

            // Mic detector threshold sync
            audioEngine.micDetector.threshold = micThreshold

            // Playback indítás
            audioEngine.play()
            appState = .countIn(clicksSoFar: 0)
            errorMessage = nil
        } catch {
            errorMessage = "Hiba: \(error.localizedDescription)"
        }
    }

    func stop() {
        audioEngine.stop()
        timingEngine.stop()
        resetStats()
        appState = .idle
    }

    // MARK: - Private

    private func handlePlaybackFinished() {
        timingEngine.stop()
        appState = .idle
    }

    private func resetStats() {
        footHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
        handHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
        lastFootBin = nil
        lastHandBin = nil
        footBorderThick = false
        handBorderThick = false
    }

    // MARK: - Status text

    /// Az állapotnak megfelelő szöveg a UI-on
    var statusText: String {
        switch appState {
        case .idle:
            return "Idle"
        case .countIn(let clicks):
            return "Count-in: \(clicks)/\(TimingEngine.countInClicks)"
        case .active:
            return "● Live"
        }
    }

    /// Aktív állapotban vagyunk-e (lejátszás megy)
    var isSessionActive: Bool {
        switch appState {
        case .idle: return false
        case .countIn, .active: return true
        }
    }
}
