import Foundation
import CompassFIT
import CompassData

enum FITKind: String, CaseIterable {
    case activity, monitor, sleep, metrics

    static func infer(from filename: String) -> FITKind? {
        let lower = filename.lowercased()
        if lower.contains("activity") || lower.contains("act_") { return .activity }
        if lower.contains("monitor")  || lower.contains("mon_") { return .monitor }
        if lower.contains("sleep")    || lower.contains("slp_") { return .sleep }
        if lower.contains("metric")   || lower.contains("met_") { return .metrics }
        return nil
    }
}

struct Options {
    var path: URL?
    var paths: [URL] = []
    var explicitType: FITKind?
    var raw: Bool = false
    var profile: DeviceProfile = .default
    var mergeSleep: Bool = false
}

extension DeviceProfile {
    static func named(_ name: String) -> DeviceProfile? {
        switch name.lowercased() {
        case "default":           return .default
        case "instinct-solar-1g": return .instinctSolar1G
        default:                  return nil
        }
    }
}

private func printUsage() -> Never {
    print("""
    Usage: fitdump [--type activity|monitor|sleep|metrics] [--raw] [--profile default|instinct-solar-1g] <file.fit>

    Options:
      --type     Override type detection (activity, monitor, sleep, metrics)
      --raw      Print raw FIT message fields instead of parsed results
      --profile  Device profile for parser (default, instinct-solar-1g)
      --help     Show this help
    """)
    exit(0)
}

func parseArgs() -> Options {
    var argList = Array(CommandLine.arguments.dropFirst())
    var opts = Options()

    while !argList.isEmpty {
        let arg = argList.removeFirst()
        switch arg {
        case "--help", "-h":
            printUsage()
        case "--type":
            guard !argList.isEmpty else {
                fputs("--type requires a value\n", stderr); exit(2)
            }
            let val = argList.removeFirst()
            guard let kind = FITKind(rawValue: val) else {
                fputs("Unknown type '\(val)'. Use: \(FITKind.allCases.map(\.rawValue).joined(separator: "|"))\n", stderr)
                exit(2)
            }
            opts.explicitType = kind
        case "--raw":
            opts.raw = true
        case "--merge-sleep":
            opts.mergeSleep = true
        case "--profile":
            guard !argList.isEmpty else {
                fputs("--profile requires a value\n", stderr); exit(2)
            }
            let val = argList.removeFirst()
            guard let prof = DeviceProfile.named(val) else {
                fputs("Unknown profile '\(val)'. Use: default|instinct-solar-1g\n", stderr)
                exit(2)
            }
            opts.profile = prof
        default:
            if arg.hasPrefix("-") {
                fputs("Unknown flag: \(arg)\n", stderr); exit(2)
            }
            let url = URL(fileURLWithPath: arg)
            if opts.path == nil { opts.path = url }
            opts.paths.append(url)
        }
    }

    guard opts.path != nil else {
        fputs("Missing file argument.\n\nUsage: fitdump [--type activity|monitor|sleep|metrics] [--raw] [--profile default|instinct-solar-1g] [--merge-sleep] <file.fit>...\n", stderr)
        exit(2)
    }
    return opts
}

@main
struct FitDumpTool {
    static func main() async {
        let opts = parseArgs()

        do {
            if opts.mergeSleep {
                try await dumpMergedSleep(urls: opts.paths, profile: opts.profile)
                return
            }

            let data = try Data(contentsOf: opts.path!)

            if opts.raw {
                dumpRaw(data: data)
                return
            }

            let kind = opts.explicitType ?? FITKind.infer(from: opts.path!.lastPathComponent)
            guard let kind else {
                fputs("Cannot infer type from '\(opts.path!.lastPathComponent)'. Pass --type activity|monitor|sleep|metrics.\n", stderr)
                exit(2)
            }

            switch kind {
            case .activity: try await dumpActivity(data: data, profile: opts.profile)
            case .monitor:  try await dumpMonitoring(data: data, profile: opts.profile)
            case .sleep:    try await dumpSleep(data: data, profile: opts.profile)
            case .metrics:  try await dumpMetrics(data: data)
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
}
