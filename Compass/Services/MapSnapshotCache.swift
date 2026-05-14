import Foundation
import UIKit

/// Two-tier cache (NSCache + Caches/MapSnapshots PNG) for `MKMapSnapshotter`
/// outputs. Map renders are deterministic per route, so we key by a caller-
/// supplied stable identifier (typically `Activity.id` or `Course.id`) plus the
/// pixel size of the snapshot.
final class MapSnapshotCache: @unchecked Sendable {
    static let shared = MapSnapshotCache()

    // NSCache is documented as thread-safe (Apple guarantees lock-free
    // get/set across threads), but it isn't Sendable. The `unsafe` attribute
    // tells Swift's strict concurrency to trust the documented contract so
    // the cache can be captured into background ioQueue blocks.
    nonisolated(unsafe) private let memCache: NSCache<NSString, UIImage>
    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "MapSnapshotCache.io", qos: .utility)

    private init() {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        memCache = cache

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = cachesDir.appendingPathComponent("MapSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    /// Memory hit returns synchronously; disk hit promotes into memory and returns.
    func image(forKey key: String) async -> UIImage? {
        if let cached = memCache.object(forKey: key as NSString) { return cached }
        return await readFromDisk(key: key)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memCache.setObject(image, forKey: key as NSString, cost: cost)
        ioQueue.async { [diskDir] in
            let url = diskDir.appendingPathComponent("\(key).png")
            if let data = image.pngData() {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func readFromDisk(key: String) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            ioQueue.async { [memCache, diskDir] in
                let url = diskDir.appendingPathComponent("\(key).png")
                guard let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                memCache.setObject(image, forKey: key as NSString, cost: data.count)
                cont.resume(returning: image)
            }
        }
    }
}
