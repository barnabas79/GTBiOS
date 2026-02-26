import AVFoundation

/// Az audio engine felépítése és kezelése.
///
/// Architektúra — „pre-extraction" megközelítés:
///
/// 1. **Fájl betöltés:** a sztereó WAV/CAF-ból kinyerjük:
///    - **L csatorna (click):** offline onset-detektálás → `clickOnsetSamples` tömb
///    - **R csatorna (zene):** mono `AVAudioPCMBuffer` → ez szól a fülhallgatóban
///
/// 2. **Lejátszás:** `playerNode` a mono R buffert játssza. Egyetlen player tap
///    rögzíti a playback **origin hostTime-ot** (sample 0 → hostTime mapping).
///
/// 3. **Mikrofon:** `inputNode` tap → `OnsetDetector` valós időben.
///
/// **Miért nem módosítjuk a tap-ben a buffert?**
/// Az `AVAudioNode.installTap` egy köztes mixer-t hoz létre; a callback-ben kapott
/// buffer módosítása NEM hat a downstream audio-ra. Ezért nem működne az „L csatorna
/// kinullázása a tap-ben" megközelítés. A pre-extraction ezt elkerüli.
final class AudioEngineManager {

    // MARK: - Audio Engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // MARK: - Pre-extracted data

    /// A mono R csatorna (zene) — ezt játssza a playerNode
    private var monoPlaybackBuffer: AVAudioPCMBuffer?

    /// Click onset pozíciók (sample/frame index a fájl elejétől), offline detektálva
    private(set) var clickOnsetSamples: [Int] = []

    /// A fájl mintavételi frekvenciája
    private(set) var sampleRate: Double = 44100

    // MARK: - Playback origin (időtengely)

    /// A playback origin hostTime (nanosec): sample 0 mikor szólal meg.
    /// Az első player tap callback-ből számoljuk ki.
    private(set) var playbackOriginHostTimeNs: UInt64 = 0

    /// Flag: origin már ki lett számolva
    private var originCaptured = false

    // MARK: - Onset detektor (mikrofon, valós idejű)

    let micDetector = OnsetDetector(channelIndex: 0, threshold: 0.1, deadTimeSec: 0.1)

    // MARK: - Callbacks

    /// Meghívódik amikor a lejátszás természetesen véget ér
    var onPlaybackFinished: (() -> Void)?

    /// Meghívódik amikor a playback origin kiszámolódott (hostTimeNs)
    var onOriginCaptured: ((UInt64) -> Void)?

    /// Meghívódik minden player tap buffer-nél (hostTimeNs) — count-in progress tracking-hez
    var onPlayerTick: ((UInt64) -> Void)?

    // MARK: - State

    private(set) var isPlaying = false
    private var playerTapInstalled = false
    private var micTapInstalled = false

    /// Click threshold az offline detektáláshoz (állítható a UI-ból, újra-analizálást triggerel)
    var clickThreshold: Float = 0.15

    // MARK: - Init

    init() {}

    // MARK: - Audio Session

    /// Konfigurálja az AVAudioSession-t: playAndRecord, measurement mode, no BT, kis buffer
    func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Category: playAndRecord — lejátszás + mikrofon egyszerre
        // Mode: measurement — kikapcsolja az AGC-t, noise suppression-t, echo cancellation-t
        // Options: üres — sem defaultToSpeaker, sem allowBluetooth, sem mixWithOthers
        try session.setCategory(.playAndRecord, mode: .measurement, options: [])

        // Preferált I/O buffer méret: ~5.3ms (256 frame @ 48kHz)
        try session.setPreferredIOBufferDuration(0.005)

        try session.setActive(true)
    }

    // MARK: - File loading + pre-extraction

    /// Betölti a sztereó audio fájlt, kinyeri az R csatornát (zene) és
    /// offline onset-detektálja az L csatornát (click).
    /// - Parameter url: a WAV/CAF/AIFF fájl URL-je
    func loadFile(url: URL) throws {
        // Security-scoped resource access
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        guard format.channelCount == 2 else {
            throw AudioEngineError.notStereo
        }

        self.sampleRate = format.sampleRate

        // Teljes fájl beolvasása PCM bufferbe
        let frameCount = AVAudioFrameCount(file.length)
        guard let stereoBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioEngineError.bufferCreationFailed
        }
        try file.read(into: stereoBuffer)

        guard let channelData = stereoBuffer.floatChannelData else {
            throw AudioEngineError.bufferCreationFailed
        }

        let frames = Int(stereoBuffer.frameLength)
        let leftChannel = channelData[0]   // click
        let rightChannel = channelData[1]  // zene

        // 1. Offline click onset detektálás (L csatorna)
        self.clickOnsetSamples = OnsetDetector.detectOnsetsOffline(
            samples: leftChannel,
            frameCount: frames,
            sampleRate: sampleRate,
            threshold: clickThreshold,
            deadTimeSec: 0.08  // 80ms dead time click-hez
        )

        // 2. R csatorna → mono AVAudioPCMBuffer (lejátszáshoz)
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw AudioEngineError.bufferCreationFailed
        }

        guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            throw AudioEngineError.bufferCreationFailed
        }
        monoBuf.frameLength = AVAudioFrameCount(frames)

        guard let monoData = monoBuf.floatChannelData else {
            throw AudioEngineError.bufferCreationFailed
        }

        // R csatorna másolása a mono bufferbe
        let monoChannel = monoData[0]
        for i in 0..<frames {
            monoChannel[i] = rightChannel[i]
        }

        self.monoPlaybackBuffer = monoBuf
    }

    /// Újrafuttatja az offline click detektálást az aktuális clickThreshold-dal.
    /// Csak ha van betöltött fájl. (URL-t újra nem kell megadni, mert a buffer megvan.)
    func reanalyzeClicks(leftChannelSamples: UnsafePointer<Float>? = nil) {
        // Ez a metódus opcionális — MVP-ben a loadFile-nál futtatott detektálás elég.
        // Ha kell: a stereo buffert is el kéne menteni, de MVP-ben nem tároljuk.
    }

    // MARK: - Engine setup

    /// Az engine topológiát felépíti. `loadFile` után kell hívni.
    func setupEngine() throws {
        guard let playbackBuffer = monoPlaybackBuffer else {
            throw AudioEngineError.noFileLoaded
        }

        // Reset
        engine.stop()
        removeTaps()
        engine.reset()
        originCaptured = false
        playbackOriginHostTimeNs = 0

        // PlayerNode hozzáadása
        engine.attach(playerNode)

        // Player → mainMixer (mono)
        let monoFormat = playbackBuffer.format
        engine.connect(playerNode, to: engine.mainMixerNode, format: monoFormat)

        // Player tap — az origin hostTime kiszámolásához és tick-ekhez
        let tapBufferSize: AVAudioFrameCount = 512
        playerNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: monoFormat) { [weak self] buffer, time in
            guard let self = self else { return }

            if !self.originCaptured, time.isSampleTimeValid, time.isHostTimeValid {
                // Origin kiszámolása: a buffer hostTime-jából és a playerTime-ból
                // sampleTime = hány sample ment el a playerNode-on → player time pozíció
                // hostTime = az adott buffer abszolút ideje
                // origin = hostTime - (sampleTime / sampleRate) * 1e9
                let sampleTimeInPlayer = time.sampleTime
                let hostTimeNs = HostTimeConverter.hostTimeToNs(time.hostTime)
                let offsetNs = UInt64(Double(sampleTimeInPlayer) / self.sampleRate * 1_000_000_000)

                self.playbackOriginHostTimeNs = hostTimeNs - offsetNs
                self.originCaptured = true
                self.onOriginCaptured?(self.playbackOriginHostTimeNs)
            }

            // Tick callback (count-in progress tracking-hez)
            if self.originCaptured {
                let currentHostTimeNs = HostTimeConverter.hostTimeToNs(time.hostTime)
                self.onPlayerTick?(currentHostTimeNs)
            }
        }
        playerTapInstalled = true

        // Mic input tap
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: micFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            self.micDetector.process(buffer: buffer, when: time)
        }
        micTapInstalled = true

        // Engine indítás
        engine.prepare()
        try engine.start()
    }

    // MARK: - Playback control

    /// Lejátszás indítása az elejéről
    func play() {
        guard let buffer = monoPlaybackBuffer else { return }

        // Reset
        micDetector.reset()
        originCaptured = false
        playbackOriginHostTimeNs = 0

        playerNode.scheduleBuffer(buffer, at: nil) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.onPlaybackFinished?()
            }
        }

        playerNode.play()
        isPlaying = true
    }

    /// Lejátszás megállítása
    func stop() {
        playerNode.stop()
        isPlaying = false
    }

    // MARK: - Cleanup

    private func removeTaps() {
        if playerTapInstalled {
            playerNode.removeTap(onBus: 0)
            playerTapInstalled = false
        }
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
    }

    func teardown() {
        stop()
        removeTaps()
        engine.stop()
        engine.detach(playerNode)
    }
}

// MARK: - Errors

enum AudioEngineError: LocalizedError {
    case notStereo
    case noFileLoaded
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .notStereo:
            return "A fájlnak sztereónak kell lennie (2 csatorna: L=click, R=zene)."
        case .noFileLoaded:
            return "Nincs betöltött audio fájl."
        case .bufferCreationFailed:
            return "Nem sikerült audio buffert létrehozni."
        }
    }
}
