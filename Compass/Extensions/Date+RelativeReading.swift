import Foundation

extension Date {
    /// "54 minutes ago" when within an hour, "at 15:30" otherwise.
    func relativeReadingDescription(now: Date = .now) -> String {
        let minutes = Int(now.timeIntervalSince(self) / 60)
        if minutes < 60 {
            let m = max(1, minutes)
            return "\(m) minute\(m == 1 ? "" : "s") ago"
        }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "at " + f.string(from: self)
    }
}
