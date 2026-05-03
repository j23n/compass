@preconcurrency import FitFileParser
import Foundation

private let dateTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func fieldStr(_ fv: FitFieldValue) -> String {
    if let t = fv.time {
        return dateTimeFmt.string(from: t) + " UTC"
    }
    if let c = fv.coordinate {
        return String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }
    if let vu = fv.valueUnit {
        return String(format: "%g %@", vu.value, vu.unit)
    }
    if let v = fv.value {
        return String(format: "%g", v)
    }
    if let n = fv.name {
        return n
    }
    return "(nil)"
}

func dumpRaw(data: Data) {
    let fitFile = FitFile(data: data)
    for (idx, message) in fitFile.messages.enumerated() {
        let typeNum  = Int(message.messageType)
        let typeName = message.messageType.name()
        print("[#\(idx)] mesg=\(typeNum) \(typeName)")
        let fields = message.interpretedFields().sorted { $0.key < $1.key }
        for (key, fv) in fields {
            print("  \(key) = \(fieldStr(fv))")
        }
    }
}
