import Foundation
import CoreGraphics

struct StoredPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct TracerProject: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var videoFilename: String
    var startPoint: StoredPoint
    var apexPoint: StoredPoint
    var endPoint: StoredPoint
    var startTime: Double
    var endTime: Double
    var apexTiming: Double
    var curve: Double
    var trailLength: Double
    var mirrored: Bool
    var updatedAt = Date()
}

enum TracerProjectStore {
    private static let filename = "CurrentTrace.json"

    static var projectsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("GolfTracer", isDirectory: true)
    }

    static var projectURL: URL { projectsDirectory.appendingPathComponent(filename) }

    static func importVideo(from temporaryURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let destination = projectsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(temporaryURL.pathExtension.isEmpty ? "mov" : temporaryURL.pathExtension)
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    static func save(_ project: TracerProject) throws {
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.projectEncoder.encode(project)
        try data.write(to: projectURL, options: .atomic)
    }

    static func load() throws -> (TracerProject, URL)? {
        guard FileManager.default.fileExists(atPath: projectURL.path) else { return nil }
        let data = try Data(contentsOf: projectURL)
        let project = try JSONDecoder.projectDecoder.decode(TracerProject.self, from: data)
        guard project.version == TracerProject.currentVersion else { return nil }
        let videoURL = projectsDirectory.appendingPathComponent(project.videoFilename)
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
        return (project, videoURL)
    }
}

private extension JSONEncoder {
    static var projectEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var projectDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
