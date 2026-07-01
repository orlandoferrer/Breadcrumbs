import CoreServices
import Foundation

struct FinderState: Equatable {
    var displayedPath: String
    var resolvedPath: String
    var windowID: Int
}

protocol FinderAutomationServing {
    func currentState() -> FinderState?
    func navigate(to path: String, windowID: Int?) -> Bool
    func hasAutomationPermission() -> Bool
    func requestAutomationPermission() -> Bool
}

final class FinderAutomationService: FinderAutomationServing {
    func hasAutomationPermission() -> Bool {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let target = targetDescriptor.aeDesc else {
            return false
        }

        return AEDeterminePermissionToAutomateTarget(
            target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        ) == noErr
    }

    func requestAutomationPermission() -> Bool {
        run(script: #"tell application "Finder" to return name of startup disk"#, logErrors: false) != nil
    }

    func currentState() -> FinderState? {
        let script = """
        tell application "Finder"
            if not (exists front window) then
                return ""
            end if
            set currentWindow to front window
            set currentTarget to target of currentWindow
            set targetPath to ""
            set targetDescription to (currentTarget as string)
            try
                set targetPath to POSIX path of (currentTarget as alias)
            on error
                try
                    set targetPath to POSIX path of (currentTarget as text)
                on error
                    try
                    set targetURL to URL of currentTarget
                    if targetURL starts with "file://" then
                        set targetPath to POSIX path of targetURL
                    end if
                    on error
                        set targetPath to ""
                    end try
                end try
            end try
            if targetPath is "" then
                return (id of currentWindow as string) & linefeed & linefeed & targetDescription
            end if
            return (id of currentWindow as string) & linefeed & targetPath & linefeed & targetDescription
        end tell
        """

        guard let response = run(script: script, logErrors: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !response.isEmpty else {
            return nil
        }

        let lines = response.components(separatedBy: .newlines)
        guard let windowID = Int(lines.first ?? "") else {
            return nil
        }

        let directPath = lines.count >= 2 ? lines[1] : ""
        let rawDescription = lines.count >= 3 ? lines[2] : ""
        let path = !directPath.isEmpty ? directPath : parseFinderObjectPath(from: rawDescription)
        guard let path, !path.isEmpty else { return nil }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FinderState(displayedPath: path, resolvedPath: resolved, windowID: windowID)
    }

    func navigate(to path: String, windowID: Int?) -> Bool {
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

        return run(script: script, logErrors: true) != nil
    }

    private func run(script: String, logErrors: Bool) -> String? {
        var errorInfo: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            if logErrors {
                NSLog("FinderAutomationService AppleScript error: %@", errorInfo ?? [:])
            }
            return nil
        }
        return result?.stringValue
    }

    private func parseFinderObjectPath(from description: String) -> String? {
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
            if kind == "folder" {
                folders.append(name)
            } else if kind == "disk" {
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
}
