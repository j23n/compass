#if !canImport(HealthKit)
import Foundation

/// macOS / non-iOS stub. The HealthKit framework is iOS-only, but the package
/// builds on macOS for `swift test` so we provide a stub that always reports
/// unavailable. The app target never sees this path.
public actor HealthKitExporter: HealthKitExporterProtocol {

    public init(logSink: @escaping @Sendable (String) -> Void = { _ in }) {}

    public nonisolated func isAvailable() -> Bool { false }

    public func requestAuthorization() async throws -> HealthAuthorizationResult {
        .unavailable
    }

    @discardableResult
    public func export(
        snapshot: HealthDataSnapshot,
        progress: @Sendable (ExportProgress) -> Void
    ) async throws -> ExportSummary {
        throw HealthKitExporterError.unavailable
    }

    @discardableResult
    public func deleteAllCompassData() async throws -> DeletionSummary {
        throw HealthKitExporterError.unavailable
    }
}
#endif
