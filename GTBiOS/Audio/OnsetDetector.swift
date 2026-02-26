import AVFoundation

/// Rising-edge threshold crossing onset detektor.
///
/// Két használati mód:
/// 1. **Valós idejű** (mikrofon): `process(buffer:when:)` — audio tap callback-ben
/// 2. **Offline** (click csatorna): `OnsetDetector.detectOnsetsOffline(...)` — fájl betöltéskor
final class OnsetDetector {

    // MARK: - Configuration

    /// Célcsatorna index a bejövő bufferben (0 = L, 1 = R)
    let channelIndex: Int

    /// Küszöbérték (0.0–1.0 lineáris skálán). Onset = prevLevel < threshold && currLevel >= threshold.
    var threshold: Float = 0.15

    /// Dead time: ennyi ideig ignoráljuk az újabb onset-eket egy detektálás után (másodpercben).
    var deadTimeSec: Double = 0.1 // 100 ms

    // MARK: - State

    /// Az előző feldolgozott blokk utolsó szintértéke (abszolút peak)
    private var previousLevel: Float = 0.0

    /// A legutolsó onset hostTime-ja (nanosec) — dead time számításhoz
    private var lastOnsetHostTimeNs: UInt64 = 0

    /// Onset callback: (hostTimeNs: UInt64)
    var onOnset: ((UInt64) -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - channelIndex: melyik csatornát figyeljük (0 = left, 1 = right)
    ///   - threshold: onset küszöb (lineáris, 0.0–1.0)
    ///   - deadTimeSec: retrigger védelem (sec)
    init(channelIndex: Int, threshold: Float = 0.15, deadTimeSec: Double = 0.1) {
        self.channelIndex = channelIndex
        self.threshold = threshold
        self.deadTimeSec = deadTimeSec
    }

    // MARK: - Reset

    func reset() {
        previousLevel = 0.0
        lastOnsetHostTimeNs = 0
    }

    // MARK: - Valós idejű feldolgozás (mikrofon)

    /// Feldolgoz egy audio buffert, onset-eket keres benne.
    /// - Parameters:
    ///   - buffer: PCM float buffer (non-interleaved, legalább channelIndex+1 csatorna)
    ///   - when: az AVAudioTime a buffer elejéhez
    func process(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let channelData = buffer.floatChannelData,
              Int(buffer.format.channelCount) > channelIndex else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let data = channelData[channelIndex]
        let sampleRate = buffer.format.sampleRate

        // A buffer elejének hostTime-ja nanoszekundumban
        let bufferStartNs = HostTimeConverter.hostTimeToNs(when.hostTime)

        // Hop méret: kisebb blokkokban vizsgáljuk a buffert a pontosabb onset lokalizációhoz
        let hopSize = 64
        var prevLevel = self.previousLevel

        var frameOffset = 0
        while frameOffset < frameCount {
            let blockEnd = min(frameOffset + hopSize, frameCount)

            // Peak abszolút érték ebben a blokkban
            var peak: Float = 0.0
            for i in frameOffset..<blockEnd {
                let absVal = abs(data[i])
                if absVal > peak { peak = absVal }
            }

            // Rising edge threshold crossing
            if prevLevel < threshold && peak >= threshold {
                // Onset frame pozíció: a blokk közepe (legjobb becslés hop-on belül)
                let onsetFrame = Double(frameOffset + (blockEnd - frameOffset) / 2)
                let onsetOffsetSec = onsetFrame / sampleRate
                let onsetHostTimeNs = bufferStartNs + UInt64(onsetOffsetSec * 1_000_000_000)

                // Dead time ellenőrzés
                let deadTimeNs = UInt64(deadTimeSec * 1_000_000_000)
                if lastOnsetHostTimeNs == 0 || (onsetHostTimeNs - lastOnsetHostTimeNs) >= deadTimeNs {
                    lastOnsetHostTimeNs = onsetHostTimeNs
                    onOnset?(onsetHostTimeNs)
                }
            }

            prevLevel = peak
            frameOffset = blockEnd
        }

        self.previousLevel = prevLevel
    }

    // MARK: - Offline feldolgozás (click csatorna)

    /// Offline onset detektálás egy mono float tömbön.
    /// A fájl betöltésekor használjuk a click (L) csatorna előelemzésére.
    ///
    /// - Parameters:
    ///   - samples: mono float minta-tömb (nem interleaved)
    ///   - frameCount: minták száma
    ///   - sampleRate: mintavételi frekvencia
    ///   - threshold: onset küszöb (lineáris, 0.0–1.0)
    ///   - deadTimeSec: retrigger védelem (sec)
    /// - Returns: onset pozíciók (frame/sample index a tömb elejétől)
    static func detectOnsetsOffline(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        threshold: Float,
        deadTimeSec: Double
    ) -> [Int] {
        var onsets: [Int] = []
        let hopSize = 64
        let deadTimeSamples = Int(deadTimeSec * sampleRate)
        var prevLevel: Float = 0.0
        var lastOnsetFrame: Int = -deadTimeSamples - 1 // hogy az első onset is triggelődjön

        var frameOffset = 0
        while frameOffset < frameCount {
            let blockEnd = min(frameOffset + hopSize, frameCount)

            // Peak abszolút érték ebben a blokkban
            var peak: Float = 0.0
            for i in frameOffset..<blockEnd {
                let absVal = abs(samples[i])
                if absVal > peak { peak = absVal }
            }

            // Rising edge threshold crossing
            if prevLevel < threshold && peak >= threshold {
                let onsetFrame = frameOffset + (blockEnd - frameOffset) / 2

                // Dead time ellenőrzés
                if (onsetFrame - lastOnsetFrame) >= deadTimeSamples {
                    onsets.append(onsetFrame)
                    lastOnsetFrame = onsetFrame
                }
            }

            prevLevel = peak
            frameOffset = blockEnd
        }

        return onsets
    }
}
