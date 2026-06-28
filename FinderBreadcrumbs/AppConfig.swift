import AppKit
import Carbon
import Foundation

struct AppConfig: Codable {
    enum DisplayMode: String, Codable {
        case text
        case breadcrumb
    }

    struct Shortcut: Codable {
        var keyCode: UInt32
        var modifiers: UInt32

        static let `default` = Shortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(optionKey | cmdKey)
        )
    }

    var displayMode: DisplayMode
    var launchAtLogin: Bool
    var trackOnlyFrontmostFinderWindow: Bool
    var activePollInterval: TimeInterval
    var motionPollInterval: TimeInterval
    var motionTrackingDuration: TimeInterval
    var inactivePollInterval: TimeInterval
    var horizontalInset: CGFloat
    var verticalGap: CGFloat
    var preferredBarHeight: CGFloat
    var shortcut: Shortcut

    static let `default` = AppConfig(
        displayMode: .text,
        launchAtLogin: false,
        trackOnlyFrontmostFinderWindow: true,
        activePollInterval: 0.12,
        motionPollInterval: 0.016,
        motionTrackingDuration: 0.2,
        inactivePollInterval: 1.5,
        horizontalInset: 8,
        verticalGap: -6,
        preferredBarHeight: 34,
        shortcut: .default
    )
}

enum AppConfigLoader {
    static let appSupportDirectoryName = "FinderBreadcrumbs"
    static let configFileName = "config.json"

    static func load() -> AppConfig {
        let fileManager = FileManager.default
        let url = configURL(fileManager: fileManager)

        guard let data = try? Data(contentsOf: url) else {
            createDefaultConfigIfNeeded(at: url, fileManager: fileManager)
            return .default
        }

        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return .default
        }
    }

    static func configURL(fileManager: FileManager = .default) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return baseURL
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(configFileName)
    }

    private static func createDefaultConfigIfNeeded(at url: URL, fileManager: FileManager) {
        let parent = url.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: url.path) else { return }

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try JSONEncoder.pretty.encode(AppConfig.default)
            try data.write(to: url)
        } catch {
            // Leave config creation best-effort so the app still launches.
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
