import Foundation

public enum LogPaths {
    /// ~/Library/Logs/Jarvis/
    public static var channelDirectory: URL {
        let fm = FileManager.default
        let libraryURL: URL
        do {
            libraryURL = try fm.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        } catch {
            libraryURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library"))
        }
        let dir = libraryURL.appendingPathComponent("Logs/Jarvis", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
