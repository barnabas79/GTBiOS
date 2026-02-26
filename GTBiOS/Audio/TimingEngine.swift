import Foundation

/// Koordináló réteg: állapotgép, count-in, tempó grid, matching, hisztogram.
///
/// Architektúra — „pre-computed grid + hit-driven matching":
///
/// 1. A click onset pozíciók (sample index-ek) offline jönnek az `AudioEngineManager`-ből.
/// 2. A playback origin hostTime megérkezésekor minden click pozíciót abszolút
///    hostTime-ra konvertálunk.
/// 3. Count-in: az első 16 click kiszámolt hostTime-ja alapján figyeljük (tick),
///    mikor lépünk active fázisba.
/// 4. Active fázis: mic hit → legközelebbi grid pozíció → delta → bin → hisztogram.
///    A grid a count-in click-ekből számolt átlagos intervallummal extrapolál,
///    tehát a grid NEM függ az összes pre-computed click pozíciótól — csak a tempótól
///    és az origótól.
///
/// **Miért hit-driven?** Mert ha a dobos siet, az ütése a click ELŐTT érkezik.
/// Click-driven matching-gel ehhez nem lenne referencia. A prediktált grid-del
/// azonnal kiértékelhető.
final class TimingEngine {

    // MARK: - Configuration

    /// Hány count-in click (4 taktus × 4 negyed = 16)
    static let countInClicks = 16

    /// Matching ablak: ±50 ms — ezen kívüli ütéseket eldobjuk
    static let matchWindowMs: Double = 50.0

    /// Bin-ek száma a hisztogramban (páratlan, közepén az origó)
    static let binCount = 9

    /// Latency offset (ms) — kézzel állítható slider-rel
    var latencyOffsetMs: Double = 0.0

    // MARK: - Pre-computed data

    /// Click onset pozíciók (sample index a fájl elejétől), offline detektálva
    private var clickOnsetSamples: [Int] = []

    /// Mintavételi frekvencia
    private var sampleRate: Double = 44100

    /// Abszolút click hostTime-ok (ns), a playback origin alapján kiszámolva
    private var clickHostTimesNs: [UInt64] = []

    // MARK: - State

    /// Aktuális állapot
    private(set) var state: AppState = .idle

    /// Kiszámolt click intervallum nanoszekundumban (a count-in click-ekből)
    private(set) var clickIntervalNs: UInt64 = 0

    /// Grid origó: az első éles beat (17. click) hostTime-ja ns-ben
    private(set) var gridOriginNs: UInt64 = 0

    /// Hány count-in click ideje telt el eddig (tick alapján frissül)
    private var countInClicksPassed: Int = 0

    /// A playback origin megérkezett-e
    private var originReady = false

    // MARK: - Histogram

    /// FOOT hisztogram (9 bin, kumulatív)
    private(set) var footHistogram = [Int](repeating: 0, count: TimingEngine.binCount)

    /// HAND hisztogram (9 bin, kumulatív)
    private(set) var handHistogram = [Int](repeating: 0, count: TimingEngine.binCount)

    /// Utolsó FOOT ütés bin indexe (nil ha még nem volt)
    private(set) var lastFootBin: Int? = nil

    /// Utolsó HAND ütés bin indexe
    private(set) var lastHandBin: Int? = nil

    /// FOOT keret váltakozás (vékony/vastag)
    private(set) var footBorderThick: Bool = false

    /// HAND keret váltakozás
    private(set) var handBorderThick: Bool = false

    // MARK: - Callbacks

    /// Állapotváltozás értesítés
    var onStateChanged: ((AppState) -> Void)?

    /// Új timing event (hisztogram frissült)
    var onTimingEvent: ((TimingEvent) -> Void)?

    // MARK: - Init

    init() {}

    // MARK: - Reset

    /// Teljes reset: idle állapotba
    func reset() {
        state = .idle
        clickOnsetSamples = []
        clickHostTimesNs = []
        clickIntervalNs = 0
        gridOriginNs = 0
        countInClicksPassed = 0
        originReady = false
        footHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
        handHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
        lastFootBin = nil
        lastHandBin = nil
        footBorderThick = false
        handBorderThick = false
    }

    // MARK: - Setup

    /// Pre-computed click pozíciók beállítása (fájl betöltés után, playback előtt)
    /// - Parameters:
    ///   - clickSamples: onset pozíciók (sample index)
    ///   - sampleRate: mintavételi frekvencia
    func configure(clickOnsetSamples: [Int], sampleRate: Double) {
        self.clickOnsetSamples = clickOnsetSamples
        self.sampleRate = sampleRate
    }

    // MARK: - Start / Stop

    /// Playback indult → count-in fázis
    func start() {
        // Stat resetje, de click pozíciók maradnak
        state = .countIn(clicksSoFar: 0)
        clickHostTimesNs = []
        clickIntervalNs = 0
        gridOriginNs = 0
        countInClicksPassed = 0
        originReady = false
        footHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
        handHistogram = [Int](repeating: 0, count: TimingEngine.binCount)
        lastFootBin = nil
        lastHandBin = nil
        footBorderThick = false
        handBorderThick = false
        onStateChanged?(state)
    }

    /// Playback vége → idle
    func stop() {
        state = .idle
        originReady = false
        onStateChanged?(state)
    }

    // MARK: - Playback origin

    /// Megkapta a playback origin hostTime-ot az AudioEngineManager-ből.
    /// Innentől minden click sample pozíciót abszolút hostTime-ra konvertálunk.
    func setPlaybackOrigin(hostTimeNs: UInt64) {
        guard !originReady else { return }
        originReady = true

        // Click sample pozíciók → abszolút hostTime
        clickHostTimesNs = clickOnsetSamples.map { samplePos in
            let offsetNs = UInt64(Double(samplePos) / sampleRate * 1_000_000_000)
            return hostTimeNs + offsetNs
        }

        // Ha elegendő click van a count-in-hez, előre kiszámoljuk a tempót és a gridet
        if clickHostTimesNs.count >= TimingEngine.countInClicks {
            buildGrid()
        }
    }

    // MARK: - Tick (player tap callback-ből, rendszeres)

    /// Rendszeres frissítés a player tap-ből. Count-in progress tracking.
    func tick(currentHostTimeNs: UInt64) {
        guard originReady else { return }

        switch state {
        case .countIn:
            // Hány count-in click pozíció telt már el?
            let countInCount = min(TimingEngine.countInClicks, clickHostTimesNs.count)
            var passed = 0
            for i in 0..<countInCount {
                if currentHostTimeNs >= clickHostTimesNs[i] {
                    passed = i + 1
                }
            }

            if passed != countInClicksPassed {
                countInClicksPassed = passed
                state = .countIn(clicksSoFar: passed)
                onStateChanged?(state)
            }

            // Count-in vége: ha az utolsó count-in click is eltelt ÉS a grid origó is eltelt
            if passed >= countInCount && gridOriginNs > 0 && currentHostTimeNs >= gridOriginNs {
                state = .active
                onStateChanged?(state)
            }

        case .active, .idle:
            break
        }
    }

    // MARK: - Mic hit (mikrofon onset)

    /// Meghívódik amikor a mic onset detektor ütést talál.
    /// Active állapotban azonnal kiértékeli a grid alapján.
    func handleMicHit(hostTimeNs: UInt64) {
        guard case .active = state else { return }
        guard clickIntervalNs > 0, gridOriginNs > 0 else { return }

        // Legközelebbi grid pozíció keresése
        let hitRelativeNs = Int64(hostTimeNs) - Int64(gridOriginNs)
        let intervalNsSigned = Int64(clickIntervalNs)

        // Kerekített grid index (lehet negatív is elvileg, de active fázisban nem fordul elő)
        let gridIndex: Int64
        if hitRelativeNs >= 0 {
            gridIndex = (hitRelativeNs + intervalNsSigned / 2) / intervalNsSigned
        } else {
            gridIndex = (hitRelativeNs - intervalNsSigned / 2) / intervalNsSigned
        }

        // Legközelebbi grid pozíció hostTime-ja
        let nearestGridNs = UInt64(Int64(gridOriginNs) + gridIndex * intervalNsSigned)

        // Delta (ms) — pozitív = késik, negatív = siet
        let rawDeltaMs = HostTimeConverter.deltaMs(from: nearestGridNs, to: hostTimeNs)
        let correctedDeltaMs = rawDeltaMs - latencyOffsetMs

        // ±50 ms ablakon kívüli → eldobás
        guard abs(correctedDeltaMs) <= TimingEngine.matchWindowMs else { return }

        // FOOT/HAND bontás: gridIndex % 4 → 0,2 = FOOT  /  1,3 = HAND
        let beatPosition = Int(((gridIndex % 4) + 4) % 4)  // mindig 0–3
        let beatType: BeatType = (beatPosition == 0 || beatPosition == 2) ? .foot : .hand

        // Bin index számítás
        let binIndex = Self.deltaMsToBin(correctedDeltaMs)

        // Hisztogram frissítés
        if let bin = binIndex {
            switch beatType {
            case .foot:
                footHistogram[bin] += 1
                lastFootBin = bin
                footBorderThick.toggle()
            case .hand:
                handHistogram[bin] += 1
                lastHandBin = bin
                handBorderThick.toggle()
            }
        }

        // Event callback
        let event = TimingEvent(
            hitHostTimeNs: hostTimeNs,
            gridHostTimeNs: nearestGridNs,
            correctedDeltaMs: correctedDeltaMs,
            beatType: beatType,
            binIndex: binIndex
        )
        onTimingEvent?(event)
    }

    // MARK: - Grid

    /// A pre-computed count-in click pozíciókból kiszámolja a tempót és a grid origót.
    private func buildGrid() {
        let countInCount = min(TimingEngine.countInClicks, clickHostTimesNs.count)
        guard countInCount >= 2 else { return }

        // Átlagos intervallum: (utolsó count-in click - első) / (count - 1)
        let first = clickHostTimesNs[0]
        let last = clickHostTimesNs[countInCount - 1]
        let intervals = countInCount - 1

        clickIntervalNs = (last - first) / UInt64(intervals)

        // Grid origó: az első éles beat = utolsó count-in click + 1 intervallum
        gridOriginNs = last + clickIntervalNs
    }

    // MARK: - Bin mapping

    /// correctedDeltaMs → bin index (0–8)
    /// Tartomány: -50 ms … +50 ms, 9 bin, mindegyik ~11.11 ms széles
    /// Bin 0 = [-50, -38.89), Bin 4 = [-5.56, +5.56), Bin 8 = [+38.89, +50]
    /// nil ha a delta kívül esik a ±50 ms tartományon
    static func deltaMsToBin(_ deltaMs: Double) -> Int? {
        let windowMs = matchWindowMs
        guard abs(deltaMs) <= windowMs else { return nil }

        // Normalizálás 0..1 tartományra: -50 → 0.0, +50 → 1.0
        let normalized = (deltaMs + windowMs) / (2.0 * windowMs)
        var bin = Int(normalized * Double(binCount))

        // Clamp [0, binCount-1]
        bin = max(0, min(binCount - 1, bin))
        return bin
    }
}
