import Foundation

public enum ArchiveFixtures {
    public static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }
}
