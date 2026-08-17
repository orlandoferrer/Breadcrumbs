import CoreServices
import Foundation

/// The active Finder tab's path plus the ID of its containing Finder window.
/// The window ID prevents a path from being applied to the wrong window during
/// rapid focus or tab changes.
struct FinderState: Equatable {
    var displayedPath: String
    var resolvedPath: String
    var windowID: Int
}

/// A testable boundary around all commands sent to Finder via Apple Events.
protocol FinderAutomationServing: AnyObject, Sendable {
    func currentState() -> FinderState?
    func navigate(to path: String, windowID: Int?) -> Bool
}

protocol AppleScriptExecuting {
    func execute(_ script: NSAppleScript, errorInfo: inout NSDictionary?) -> NSAppleEventDescriptor
}

struct SystemAppleScriptExecutor: AppleScriptExecuting {
    func execute(_ script: NSAppleScript, errorInfo: inout NSDictionary?) -> NSAppleEventDescriptor {
        script.executeAndReturnError(&errorInfo)
    }
}

/// Reads and changes Finder state using its public AppleScript dictionary.
///
/// `NSAppleScript` is synchronous. The tracker calls its dedicated service on a
/// serial utility queue, while navigation uses a separate service on the main
/// actor. Do not share one instance across concurrent queues.
final class FinderAutomationService: FinderAutomationServing, @unchecked Sendable {
    private let scriptExecutor: AppleScriptExecuting

    private lazy var currentStateScript: NSAppleScript? = {
        let script = NSAppleScript(source: Self.currentStateScriptSource)
        script?.compileAndReturnError(nil)
        return script
    }()

    init(scriptExecutor: AppleScriptExecuting = SystemAppleScriptExecutor()) {
        self.scriptExecutor = scriptExecutor
    }

    func currentState() -> FinderState? {
        guard let response = run(currentStateScript, logErrors: false)?.stringValue else {
            return nil
        }

        return Self.parseFinderStateResponse(response)
    }

    static func parseFinderStateResponse(_ response: String) -> FinderState? {
        let response = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { return nil }

        // The script returns four newline-delimited fields: window ID, direct
        // POSIX path, Finder object description, and Finder's file URL.
        let lines = response.components(separatedBy: .newlines)
        guard let windowID = Int(lines.first ?? "") else {
            return nil
        }

        let directPath = lines.count >= 2 ? lines[1] : ""
        let rawDescription = lines.count >= 3 ? lines[2] : ""
        let rawURL = lines.count >= 4 ? lines[3] : ""
        let path = !directPath.isEmpty
            ? directPath
            : parseFinderFileURL(rawURL) ?? parseFinderObjectPath(from: rawDescription)
        guard let path, !path.isEmpty else { return nil }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FinderState(displayedPath: path, resolvedPath: resolved, windowID: windowID)
    }

    static let currentStateScriptSource = """
        tell application "Finder"
            if not (exists front window) then
                return ""
            end if
            set currentWindow to front window
            set currentTarget to target of currentWindow
            set targetPath to ""
            set targetDescription to ""
            set targetURL to ""
            try
                set targetDescription to (currentTarget as string)
            on error errorMessage
                -- Finder can resolve some AFP folders internally but still
                -- reject every public path/URL coercion with error -1700. The
                -- error embeds the complete cdis/cfol object chain, so retain
                -- it for the parser's last-resort AFP fallback below.
                set targetDescription to errorMessage
            end try
            try
                set targetPath to POSIX path of (currentTarget as alias)
            on error
                try
                    set targetPath to POSIX path of (currentTarget as text)
                on error
                    try
                        set targetURL to URL of currentTarget
                    on error
                        set targetURL to ""
                    end try
                end try
            end try
            if targetPath is "" then
                return (id of currentWindow as string) & linefeed & linefeed & targetDescription & linefeed & targetURL
            end if
            return (id of currentWindow as string) & linefeed & targetPath & linefeed & targetDescription & linefeed & targetURL
        end tell
        """

    func navigate(to path: String, windowID: Int?) -> Bool {
        // Validate before asking Finder so invalid input remains editable and the
        // caller can present immediate failure feedback.
        let standardized = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: standardized).standardizedFileURL.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if let windowID {
            script = """
            tell application "Finder"
                activate
                if exists (first Finder window whose id is \(windowID)) then
                    set target of (first Finder window whose id is \(windowID)) to (POSIX file "\(escaped)" as alias)
                else
                    if not (exists Finder window 1) then
                        make new Finder window
                    end if
                    set target of Finder window 1 to (POSIX file "\(escaped)" as alias)
                end if
            end tell
            """
        } else {
            script = """
            tell application "Finder"
                activate
                if not (exists Finder window 1) then
                    make new Finder window
                end if
                set target of Finder window 1 to (POSIX file "\(escaped)" as alias)
            end tell
            """
        }

        return run(NSAppleScript(source: script), logErrors: true) != nil
    }

    private var lastQuietErrorNumber: Int?

    private func run(_ appleScript: NSAppleScript?, logErrors: Bool) -> NSAppleEventDescriptor? {
        guard let appleScript else { return nil }

        var errorInfo: NSDictionary?
        let result = scriptExecutor.execute(appleScript, errorInfo: &errorInfo)
        if let errorInfo {
            let errorNumber = errorInfo[NSAppleScript.errorNumber] as? Int
            if logErrors {
                NSLog("FinderAutomationService AppleScript error: %@", errorInfo)
            } else if errorNumber != lastQuietErrorNumber {
                // Log polling failures once per error code so permission problems
                // (e.g. Automation consent denied, error -1743) are visible in Console.
                lastQuietErrorNumber = errorNumber
                NSLog("FinderAutomationService AppleScript polling error (suppressing repeats): %@", errorInfo)
            }
            return nil
        }
        lastQuietErrorNumber = nil
        return result
    }

    private static func parseFinderObjectPath(from description: String) -> String? {
        // This runs only after the direct POSIX path and Finder file URL were
        // unavailable. Some AFP targets fail every normal coercion with -1700,
        // even though Finder's error contains their complete object chain, for
        // example cfol "movies" ... cdis "home". Reconstructing that chain is
        // preferable to hiding the bar for an otherwise readable NAS folder.
        // Match only Finder's stable four-character class codes; the prose
        // surrounding them is localized and must not be part of the contract.
        let classCodedPattern = #"class (cfol|cdis). "([^"]+)""#
        if let path = parseFinderObjectPath(
            from: description,
            pattern: classCodedPattern,
            folderKind: "cfol",
            diskKind: "cdis"
        ) {
            return path
        }

        if description.contains(":"),
           !description.contains(" of "),
           let hfsPathStyle = CFURLPathStyle(rawValue: 1),
           let url = CFURLCreateWithFileSystemPath(
                nil,
                description as CFString,
                hfsPathStyle,
                true
           ) as URL? {
            return url.path
        }

        let pattern = #"(folder|disk) ([^"]\S*|.+?)(?= of (?:folder|disk) |$)"#
        return parseFinderObjectPath(
            from: description,
            pattern: pattern,
            folderKind: "folder",
            diskKind: "disk"
        )
    }

    private static func parseFinderObjectPath(
        from description: String,
        pattern: String,
        folderKind: String,
        diskKind: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsDescription = description as NSString
        let matches = regex.matches(
            in: description,
            range: NSRange(location: 0, length: nsDescription.length)
        )

        guard !matches.isEmpty else { return nil }

        var folders: [String] = []
        var diskName: String?

        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let kind = nsDescription.substring(with: match.range(at: 1))
            let name = nsDescription.substring(with: match.range(at: 2))
            if kind == folderKind {
                folders.append(name)
            } else if kind == diskKind {
                diskName = name
            }
        }

        guard let diskName else { return nil }

        var path = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(diskName, isDirectory: true)

        for folder in folders.reversed() {
            path.appendPathComponent(folder, isDirectory: true)
        }

        return path.path
    }

    private static func parseFinderFileURL(_ value: String) -> String? {
        guard let url = URL(string: value), url.isFileURL else { return nil }
        return url.path
    }
}
