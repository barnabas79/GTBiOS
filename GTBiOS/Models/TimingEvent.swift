import Foundation

/// Egy kiértékelt ütés találat
struct TimingEvent {
    /// A mic hit hostTime-ja
    let hitHostTimeNs: UInt64
    /// A legközelebbi grid pozíció hostTime-ja
    let gridHostTimeNs: UInt64
    /// Korrigált delta milliszekundumban (pozitív = késik, negatív = siet)
    let correctedDeltaMs: Double
    /// Melyik ütemre esett (FOOT: 1,3  /  HAND: 2,4)
    let beatType: BeatType
    /// Hányadik bin-be esik (0–8), nil ha kívül esik a ±50 ms tartományon
    let binIndex: Int?
}

/// 4/4 ütem bontás: 1,3 = láb  /  2,4 = kéz
enum BeatType: String {
    case foot = "FOOT"
    case hand = "HAND"
}
