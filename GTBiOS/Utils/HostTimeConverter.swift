import Foundation
import Darwin.Mach

/// mach_absolute_time alapú időkonverziók.
/// Az egész rendszerben hostTime (nanosec) értékeket használunk közös időtengelyként.
enum HostTimeConverter {

    // MARK: - Timebase info (egyszer számolódik, lazy static)

    private static let timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // MARK: - Konverziók

    /// mach_absolute_time tick → nanoszekundum
    static func nanoseconds(fromHostTime hostTime: UInt64) -> UInt64 {
        return hostTime * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }

    /// Két hostTime közötti különbség milliszekundumban (előjeles)
    /// `deltaMs = (b - a)` konvertálva ms-re.
    /// Pozitív ha b > a (b később van).
    static func deltaMs(from a: UInt64, to b: UInt64) -> Double {
        if b >= a {
            let diffNs = nanoseconds(fromHostTime: b - a)
            return Double(diffNs) / 1_000_000.0
        } else {
            let diffNs = nanoseconds(fromHostTime: a - b)
            return -(Double(diffNs) / 1_000_000.0)
        }
    }

    /// Aktuális idő hostTime nanoszekundumban
    static func currentHostTimeNs() -> UInt64 {
        return nanoseconds(fromHostTime: mach_absolute_time())
    }

    /// AVAudioTime.hostTime → nanoszekundum
    static func hostTimeToNs(_ hostTime: UInt64) -> UInt64 {
        return nanoseconds(fromHostTime: hostTime)
    }

    /// Nanoszekundum → milliszekundum
    static func nsToMs(_ ns: UInt64) -> Double {
        return Double(ns) / 1_000_000.0
    }

    /// Milliszekundum → nanoszekundum
    static func msToNs(_ ms: Double) -> UInt64 {
        return UInt64(ms * 1_000_000.0)
    }
}
