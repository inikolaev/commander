import Foundation

public struct FileLocation: Sendable, Equatable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

public protocol LocationReading: Sendable {
    func locations() -> [FileLocation]
}

/// Locations are rediscovered each time the picker opens, including newly mounted drives.
public struct LocalLocationReader: LocationReading {
    public init() {}

    public func locations() -> [FileLocation] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var locations = [FileLocation(name: "Home", url: home)]
        // Finder's iCloud Drive is a virtual view. This is the user's ordinary Drive folder.
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: cloud.path, isDirectory: &isDirectory), isDirectory.boolValue {
            locations.append(FileLocation(name: "iCloud Drive", url: cloud))
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]) ?? []
        let drives = volumes.compactMap { url -> FileLocation? in
            guard !url.path.hasPrefix("/System/Volumes/") else { return nil }
            let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsBrowsableKey])
            guard values?.volumeIsBrowsable != false else { return nil }
            return FileLocation(name: values?.volumeLocalizedName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent), url: url)
        }.sorted {
            if ($0.url.path == "/") != ($1.url.path == "/") { return $0.url.path == "/" }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
        var seen = Set(locations.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        for drive in drives where seen.insert(drive.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
            locations.append(drive)
        }
        return locations
    }
}
