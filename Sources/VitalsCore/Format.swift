import Foundation

public enum Format {
    public static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int(Double(b) / 1_048_576)) MB"
    }

    /// "1m", "45m", "3h", "19d". Never more precise than the reader needs.
    public static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 60 { return "\(max(m, 1))m" }
        let h = m / 60
        if h < 48 { return "\(h)h" }
        return "\(h / 24)d"
    }

    public static func ago(_ d: Date, now: Date = Date()) -> String {
        let t = now.timeIntervalSince(d)
        if t < 60 { return "just now" }
        return "\(duration(t)) ago"
    }

    public static func uptime(_ t: TimeInterval) -> String {
        let d = Int(t / 86400), h = Int(t.truncatingRemainder(dividingBy: 86400) / 3600)
        return d == 0 ? "\(h)h" : "\(d)d \(h)h"
    }
}
