import Foundation
import os

/// Manages Multi-Link handle assignments for BLE communication channels.
///
/// The MLR (Multi-Link Reliable) protocol multiplexes multiple logical channels
/// over a single BLE characteristic pair. Each channel is identified by a handle
/// (a 4-bit value, 0-15).
///
/// Handle assignments:
/// - Handle 0: Reserved for the control channel (MLR protocol management)
/// - Handle 1+: Dynamically assigned for application services (e.g., GFDI)
///
/// When a new service needs to communicate, it requests a handle via
/// ``openHandle(forService:)``. The handle is released when the service
/// disconnects via ``closeHandle(_:)``.
///
/// Reference: Gadgetbridge `GarminSupport.java` — MLR handle management.
public actor HandleManager {

    /// Known BLE service types that can be assigned handles.
    public enum ServiceType: String, Sendable {
        /// The Garmin GFDI (Garmin Flexible and Interoperable Data Interface) service.
        case gfdi

        /// The Garmin Real-Time service (e.g., live heart rate streaming).
        case realTime

        /// Unknown or custom service.
        case unknown
    }

    /// The control handle, always 0.
    public static let controlHandle: UInt8 = 0

    /// Currently assigned handles. Maps handle number to service type.
    private var assignments: [UInt8: ServiceType] = [:]

    /// The next handle number to assign.
    private var nextHandle: UInt8 = 1

    public init() {}

    /// Open a new handle for the given service type.
    ///
    /// - Parameter service: The service that needs a communication channel.
    /// - Returns: The assigned handle number (1-15).
    /// - Throws: If all handles are exhausted (unlikely with 15 available).
    public func openHandle(forService service: ServiceType) throws -> UInt8 {
        guard nextHandle <= 15 else {
            BLELogger.transport.error("All MLR handles exhausted")
            throw PairingError.authenticationFailed("MLR handle exhaustion")
        }

        let handle = nextHandle
        nextHandle += 1
        assignments[handle] = service

        BLELogger.transport.info("Opened MLR handle \(handle) for service: \(service.rawValue)")
        return handle
    }

    /// Close a previously opened handle, releasing it.
    ///
    /// - Parameter handle: The handle number to release.
    public func closeHandle(_ handle: UInt8) {
        guard handle != Self.controlHandle else {
            BLELogger.transport.warning("Cannot close control handle 0")
            return
        }
        if let service = assignments.removeValue(forKey: handle) {
            BLELogger.transport.info("Closed MLR handle \(handle) (was: \(service.rawValue))")
        }
    }

    /// Look up which service is assigned to a handle.
    ///
    /// - Parameter handle: The handle number to look up.
    /// - Returns: The service type, or nil if the handle is not assigned.
    public func service(forHandle handle: UInt8) -> ServiceType? {
        if handle == Self.controlHandle {
            return nil // Control channel has no service
        }
        return assignments[handle]
    }

    /// Reset all handle assignments. Called on disconnect.
    public func reset() {
        assignments.removeAll()
        nextHandle = 1
        BLELogger.transport.info("Reset all MLR handle assignments")
    }
}
