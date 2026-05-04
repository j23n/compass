import Foundation
import Compression

struct FileArchive {
    static func createArchive(from urls: [URL], archiveName: String) -> URL? {
        guard !urls.isEmpty else { return nil }
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let archiveURL = tempDirectory.appendingPathComponent("\(archiveName).zip")
        
        // Remove existing archive if it exists
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        
        do {
            // For simplicity on iOS, we'll create a directory with the files
            // iOS's share sheet can handle directories
            let tempDir = tempDirectory.appendingPathComponent("\(archiveName)-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // Copy all files to temp directory
            for url in urls {
                let destURL = tempDir.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.copyItem(at: url, to: destURL)
                }
            }
            
            // On iOS, sharing a directory works well
            return tempDir
        } catch {
            print("Failed to create file bundle: \(error)")
            return nil
        }
    }
    
    static func shareMultipleFiles(_ urls: [URL], archiveName: String = "files", completion: @escaping ([URL]) -> Void) {
        if urls.count == 1 {
            // Single file, share directly
            completion(urls)
            return
        }
        
        // Create a directory with all files (iOS handles this well)
        if let directoryURL = createArchive(from: urls, archiveName: archiveName) {
            completion([directoryURL])
        } else {
            // Fallback to sharing individual files
            completion(urls)
        }
    }
}