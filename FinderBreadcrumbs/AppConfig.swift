import AppKit
import Carbon
import Foundation

struct AppConfig: Codable {
    enum DisplayMode: String, Codable {
        case text
        case breadcrumb
    }

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        static let `default` = Shortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(optionKey | cmdKey)
        )

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let description = try? container.decode(String.self) {
                self = try Shortcut(description: description)
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            keyCode = try container.decode(UInt32.self, forKey: .keyCode)
            modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }

        var description: String {
            var parts: [String] = []
            if modifiers & UInt32(cmdKey) != 0 {
                parts.append("cmd")
            }
            if modifiers & UInt32(optionKey) != 0 {
                parts.append("option")
            }
            if modifiers & UInt32(shiftKey) != 0 {
                parts.append("shift")
            }
            if modifiers & UInt32(controlKey) != 0 {
                parts.append("control")
            }
            parts.append(Self.keyNamesByCode[keyCode] ?? "keycode:\(keyCode)")
            return parts.joined(separator: "+")
        }

        private init(description: String) throws {
            var modifiers: UInt32 = 0
            var keyCode: UInt32?

            for rawPart in description.split(separator: "+") {
                let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                switch part {
                case "cmd", "command":
                    modifiers |= UInt32(cmdKey)
                case "option", "opt", "alt":
                    modifiers |= UInt32(optionKey)
                case "control", "ctrl":
                    modifiers |= UInt32(controlKey)
                case "shift":
                    modifiers |= UInt32(shiftKey)
                default:
                    if let explicitKeyCode = Self.parseExplicitKeyCode(part) {
                        keyCode = explicitKeyCode
                    } else if let mappedKeyCode = Self.keyCodesByName[part] {
                        keyCode = mappedKeyCode
                    } else {
                        throw DecodingError.dataCorrupted(
                            DecodingError.Context(
                                codingPath: [],
                                debugDescription: "Unsupported shortcut key: \(part)"
                            )
                        )
                    }
                }
            }

            guard let keyCode else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Shortcut must include a key."
                    )
                )
            }

            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        private static func parseExplicitKeyCode(_ part: String) -> UInt32? {
            guard part.hasPrefix("keycode:") else { return nil }
            return UInt32(part.dropFirst("keycode:".count))
        }

        private enum CodingKeys: String, CodingKey {
            case keyCode
            case modifiers
        }

        private static let keyCodesByName: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A),
            "b": UInt32(kVK_ANSI_B),
            "c": UInt32(kVK_ANSI_C),
            "d": UInt32(kVK_ANSI_D),
            "e": UInt32(kVK_ANSI_E),
            "f": UInt32(kVK_ANSI_F),
            "g": UInt32(kVK_ANSI_G),
            "h": UInt32(kVK_ANSI_H),
            "i": UInt32(kVK_ANSI_I),
            "j": UInt32(kVK_ANSI_J),
            "k": UInt32(kVK_ANSI_K),
            "l": UInt32(kVK_ANSI_L),
            "m": UInt32(kVK_ANSI_M),
            "n": UInt32(kVK_ANSI_N),
            "o": UInt32(kVK_ANSI_O),
            "p": UInt32(kVK_ANSI_P),
            "q": UInt32(kVK_ANSI_Q),
            "r": UInt32(kVK_ANSI_R),
            "s": UInt32(kVK_ANSI_S),
            "t": UInt32(kVK_ANSI_T),
            "u": UInt32(kVK_ANSI_U),
            "v": UInt32(kVK_ANSI_V),
            "w": UInt32(kVK_ANSI_W),
            "x": UInt32(kVK_ANSI_X),
            "y": UInt32(kVK_ANSI_Y),
            "z": UInt32(kVK_ANSI_Z),
            "0": UInt32(kVK_ANSI_0),
            "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4),
            "5": UInt32(kVK_ANSI_5),
            "6": UInt32(kVK_ANSI_6),
            "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8),
            "9": UInt32(kVK_ANSI_9),
            "space": UInt32(kVK_Space),
            "tab": UInt32(kVK_Tab),
            "return": UInt32(kVK_Return),
            "enter": UInt32(kVK_Return),
            "escape": UInt32(kVK_Escape),
            "esc": UInt32(kVK_Escape),
            "delete": UInt32(kVK_Delete),
            "backspace": UInt32(kVK_Delete),
            "left": UInt32(kVK_LeftArrow),
            "right": UInt32(kVK_RightArrow),
            "up": UInt32(kVK_UpArrow),
            "down": UInt32(kVK_DownArrow)
        ]

        private static let keyNamesByCode: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "a",
            UInt32(kVK_ANSI_B): "b",
            UInt32(kVK_ANSI_C): "c",
            UInt32(kVK_ANSI_D): "d",
            UInt32(kVK_ANSI_E): "e",
            UInt32(kVK_ANSI_F): "f",
            UInt32(kVK_ANSI_G): "g",
            UInt32(kVK_ANSI_H): "h",
            UInt32(kVK_ANSI_I): "i",
            UInt32(kVK_ANSI_J): "j",
            UInt32(kVK_ANSI_K): "k",
            UInt32(kVK_ANSI_L): "l",
            UInt32(kVK_ANSI_M): "m",
            UInt32(kVK_ANSI_N): "n",
            UInt32(kVK_ANSI_O): "o",
            UInt32(kVK_ANSI_P): "p",
            UInt32(kVK_ANSI_Q): "q",
            UInt32(kVK_ANSI_R): "r",
            UInt32(kVK_ANSI_S): "s",
            UInt32(kVK_ANSI_T): "t",
            UInt32(kVK_ANSI_U): "u",
            UInt32(kVK_ANSI_V): "v",
            UInt32(kVK_ANSI_W): "w",
            UInt32(kVK_ANSI_X): "x",
            UInt32(kVK_ANSI_Y): "y",
            UInt32(kVK_ANSI_Z): "z",
            UInt32(kVK_ANSI_0): "0",
            UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4",
            UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "space",
            UInt32(kVK_Tab): "tab",
            UInt32(kVK_Return): "return",
            UInt32(kVK_Escape): "escape",
            UInt32(kVK_Delete): "delete",
            UInt32(kVK_LeftArrow): "left",
            UInt32(kVK_RightArrow): "right",
            UInt32(kVK_UpArrow): "up",
            UInt32(kVK_DownArrow): "down"
        ]
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
    var debugLogFinderWindowDiagnostics: Bool

    init(
        displayMode: DisplayMode,
        launchAtLogin: Bool,
        trackOnlyFrontmostFinderWindow: Bool,
        activePollInterval: TimeInterval,
        motionPollInterval: TimeInterval,
        motionTrackingDuration: TimeInterval,
        inactivePollInterval: TimeInterval,
        horizontalInset: CGFloat,
        verticalGap: CGFloat,
        preferredBarHeight: CGFloat,
        shortcut: Shortcut,
        debugLogFinderWindowDiagnostics: Bool
    ) {
        self.displayMode = displayMode
        self.launchAtLogin = launchAtLogin
        self.trackOnlyFrontmostFinderWindow = trackOnlyFrontmostFinderWindow
        self.activePollInterval = activePollInterval
        self.motionPollInterval = motionPollInterval
        self.motionTrackingDuration = motionTrackingDuration
        self.inactivePollInterval = inactivePollInterval
        self.horizontalInset = horizontalInset
        self.verticalGap = verticalGap
        self.preferredBarHeight = preferredBarHeight
        self.shortcut = shortcut
        self.debugLogFinderWindowDiagnostics = debugLogFinderWindowDiagnostics
    }

    init(from decoder: Decoder) throws {
        let defaults = AppConfig.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? defaults.displayMode
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        trackOnlyFrontmostFinderWindow = try container.decodeIfPresent(Bool.self, forKey: .trackOnlyFrontmostFinderWindow) ?? defaults.trackOnlyFrontmostFinderWindow
        activePollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .activePollInterval) ?? defaults.activePollInterval
        motionPollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .motionPollInterval) ?? defaults.motionPollInterval
        motionTrackingDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .motionTrackingDuration) ?? defaults.motionTrackingDuration
        inactivePollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .inactivePollInterval) ?? defaults.inactivePollInterval
        horizontalInset = try container.decodeIfPresent(CGFloat.self, forKey: .horizontalInset) ?? defaults.horizontalInset
        verticalGap = try container.decodeIfPresent(CGFloat.self, forKey: .verticalGap) ?? defaults.verticalGap
        preferredBarHeight = try container.decodeIfPresent(CGFloat.self, forKey: .preferredBarHeight) ?? defaults.preferredBarHeight
        shortcut = try container.decodeIfPresent(Shortcut.self, forKey: .shortcut) ?? defaults.shortcut
        debugLogFinderWindowDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .debugLogFinderWindowDiagnostics) ?? defaults.debugLogFinderWindowDiagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode
        case launchAtLogin
        case trackOnlyFrontmostFinderWindow
        case activePollInterval
        case motionPollInterval
        case motionTrackingDuration
        case inactivePollInterval
        case horizontalInset
        case verticalGap
        case preferredBarHeight
        case shortcut
        case debugLogFinderWindowDiagnostics
    }

    static let `default` = AppConfig(
        displayMode: .text,
        launchAtLogin: false,
        trackOnlyFrontmostFinderWindow: true,
        activePollInterval: 0.12,
        motionPollInterval: 0.016,
        motionTrackingDuration: 0.75,
        inactivePollInterval: 1.5,
        horizontalInset: 8,
        verticalGap: -6,
        preferredBarHeight: 34,
        shortcut: .default,
        debugLogFinderWindowDiagnostics: false
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

    static func save(_ config: AppConfig, fileManager: FileManager = .default) throws {
        let url = configURL(fileManager: fileManager)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: url, options: .atomic)
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
