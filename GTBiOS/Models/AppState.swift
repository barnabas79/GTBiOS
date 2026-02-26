import Foundation

/// Az app fő állapotgépe
enum AppState: Equatable {
    /// Nincs playback, fájl kiválasztható
    case idle
    /// Playback megy, count-in fázis (16 click)
    case countIn(clicksSoFar: Int)
    /// Playback megy, éles detektálás és kiértékelés
    case active
}
