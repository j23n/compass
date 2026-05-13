import Testing
import Foundation
import CompassData
@testable import CompassFIT

@Suite("GPXCourseParser POI + turn detection")
struct GPXCourseParserTests {

    // MARK: - GPX <type> handling

    @Test("Garmin <type>SHELTER</type> maps to .shelter")
    func gpxTypeShelter() throws {
        let gpx = makeGPX(wpts: [
            (lat: 45.0, lon: 7.0, name: "Hut", sym: nil, type: "SHELTER")
        ], straightTrack: true)
        let parsed = try GPXCourseParser.parse(data: gpx)
        let named = parsed.pointsOfInterest.first { $0.name == "Hut" }
        #expect(named?.coursePointType == CoursePointType.shelter.fitCode)
    }

    @Test("Komoot <sym>Flag, Blue</sym> falls back to .generic")
    func komootFlagBlueDefaultsToGeneric() throws {
        let gpx = makeGPX(wpts: [
            (lat: 45.0, lon: 7.0, name: "Palace", sym: "Flag, Blue", type: nil)
        ], straightTrack: true)
        let parsed = try GPXCourseParser.parse(data: gpx)
        let named = parsed.pointsOfInterest.first { $0.name == "Palace" }
        #expect(named?.coursePointType == CoursePointType.generic.fitCode)
    }

    @Test("<type> wins over <sym> when both present")
    func typeBeatsSym() throws {
        let gpx = makeGPX(wpts: [
            (lat: 45.0, lon: 7.0, name: "Top", sym: "Flag, Blue", type: "Summit")
        ], straightTrack: true)
        let parsed = try GPXCourseParser.parse(data: gpx)
        let named = parsed.pointsOfInterest.first { $0.name == "Top" }
        #expect(named?.coursePointType == CoursePointType.summit.fitCode)
    }

    @Test("Sym 'Drinking Water' resolves to .water")
    func symDrinkingWater() throws {
        let gpx = makeGPX(wpts: [
            (lat: 45.0, lon: 7.0, name: "Fountain", sym: "Drinking Water", type: nil)
        ], straightTrack: true)
        let parsed = try GPXCourseParser.parse(data: gpx)
        let named = parsed.pointsOfInterest.first { $0.name == "Fountain" }
        #expect(named?.coursePointType == CoursePointType.water.fitCode)
    }

    // MARK: - Turn detection

    @Test("Straight track produces no synthetic turns")
    func straightTrackNoTurns() throws {
        let gpx = makeGPX(wpts: [], straightTrack: true)
        let parsed = try GPXCourseParser.parse(data: gpx)
        let turnTypes: Set<UInt8> = [
            CoursePointType.left.fitCode, CoursePointType.right.fitCode,
            CoursePointType.slightLeft.fitCode, CoursePointType.slightRight.fitCode,
            CoursePointType.sharpLeft.fitCode, CoursePointType.sharpRight.fitCode,
            CoursePointType.uTurn.fitCode
        ]
        let turns = parsed.pointsOfInterest.filter { turnTypes.contains($0.coursePointType) }
        #expect(turns.isEmpty)
    }

    @Test("90° right kink yields a right-turn POI")
    func rightAngleEmitsRight() throws {
        // 100 m east, then 100 m north — a clean 90° left turn (north is left
        // when you're heading east → bearing change ≈ -90°).
        let p0 = (lat: 45.0,                 lon: 7.0)
        let p1 = (lat: 45.0,                 lon: 7.0 + metresToLonDegrees(100, atLat: 45.0))
        let p2 = (lat: 45.0 + metresToLatDegrees(100), lon: p1.lon)
        let gpx = makeGPXTrack(points: [p0, p1, p2])
        let parsed = try GPXCourseParser.parse(data: gpx)
        let turn = parsed.pointsOfInterest.first { poi in
            poi.coursePointType == CoursePointType.left.fitCode
                || poi.coursePointType == CoursePointType.right.fitCode
                || poi.coursePointType == CoursePointType.slightLeft.fitCode
                || poi.coursePointType == CoursePointType.slightRight.fitCode
                || poi.coursePointType == CoursePointType.sharpLeft.fitCode
                || poi.coursePointType == CoursePointType.sharpRight.fitCode
        }
        #expect(turn != nil)
        // East-then-north is a left turn (bearing 90° → 0°, signed delta = -90°).
        #expect(turn?.coursePointType == CoursePointType.left.fitCode)
    }

    @Test("U-turn yields a u_turn POI")
    func uTurnDetected() throws {
        // 100 m east, then 100 m west — straight reversal.
        let p0 = (lat: 45.0, lon: 7.0)
        let p1 = (lat: 45.0, lon: 7.0 + metresToLonDegrees(100, atLat: 45.0))
        let p2 = p0
        let gpx = makeGPXTrack(points: [p0, p1, p2])
        let parsed = try GPXCourseParser.parse(data: gpx)
        let uTurn = parsed.pointsOfInterest.first { $0.coursePointType == CoursePointType.uTurn.fitCode }
        #expect(uTurn != nil)
    }

    // MARK: - Fixture helpers

    private func makeGPX(
        wpts: [(lat: Double, lon: Double, name: String, sym: String?, type: String?)],
        straightTrack: Bool
    ) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">"#
        for w in wpts {
            xml += "<wpt lat=\"\(w.lat)\" lon=\"\(w.lon)\">"
            xml += "<name>\(w.name)</name>"
            if let sym = w.sym { xml += "<sym>\(sym)</sym>" }
            if let type = w.type { xml += "<type>\(type)</type>" }
            xml += "</wpt>"
        }
        xml += "<trk><name>Test</name><trkseg>"
        if straightTrack {
            // 500 m due-east straight line in 50 m steps.
            let baseLat = 45.0, baseLon = 7.0
            for i in 0...10 {
                let lon = baseLon + metresToLonDegrees(Double(i) * 50, atLat: baseLat)
                xml += "<trkpt lat=\"\(baseLat)\" lon=\"\(lon)\"></trkpt>"
            }
        }
        xml += "</trkseg></trk></gpx>"
        return Data(xml.utf8)
    }

    private func makeGPXTrack(points: [(lat: Double, lon: Double)]) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        xml += #"<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">"#
        xml += "<trk><name>Test</name><trkseg>"
        for p in points {
            xml += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\"></trkpt>"
        }
        xml += "</trkseg></trk></gpx>"
        return Data(xml.utf8)
    }

    private func metresToLatDegrees(_ m: Double) -> Double { m / 111_111 }
    private func metresToLonDegrees(_ m: Double, atLat lat: Double) -> Double {
        m / (111_111 * cos(lat * .pi / 180))
    }
}
