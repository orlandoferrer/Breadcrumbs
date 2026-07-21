import Foundation

struct InstallerVolumeCharacteristics: Equatable {
    var isVolumeRoot: Bool
    var isLocal: Bool
    var isReadOnly: Bool
    var isEjectable: Bool
    var isRemovable: Bool
}

enum DragToInstallVolumePolicy {
    static func shouldHideBar(
        characteristics: InstallerVolumeCharacteristics,
        containsAppBundle: Bool,
        symlinkDestinations: [String]
    ) -> Bool {
        characteristics.isVolumeRoot
            && characteristics.isLocal
            && characteristics.isReadOnly
            && characteristics.isEjectable
            && characteristics.isRemovable
            && containsAppBundle
            && symlinkDestinations.contains("/Applications")
    }
}

/// Detects Finder windows that exist only to drag an app into Applications.
///
/// These windows are ordinary Finder browser windows, so window role and title
/// checks cannot distinguish them. Installer DMGs are instead identified by a
/// conservative combination of mounted-volume metadata and root contents.
final class DragToInstallVolumeDetector {
    private let fileManager: FileManager
    private var cachedResults: [String: Bool] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func shouldHideBar(forPath path: String) -> Bool {
        let targetURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isVolumeKey,
            .volumeURLKey,
            .volumeIdentifierKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey
        ]

        guard let values = try? targetURL.resourceValues(forKeys: keys),
              let volumeURL = values.volume?.standardizedFileURL else {
            return false
        }

        let characteristics = InstallerVolumeCharacteristics(
            isVolumeRoot: values.isVolume == true && targetURL.path == volumeURL.path,
            isLocal: values.volumeIsLocal == true,
            isReadOnly: values.volumeIsReadOnly == true,
            isEjectable: values.volumeIsEjectable == true,
            isRemovable: values.volumeIsRemovable == true
        )

        guard characteristics.isVolumeRoot,
              characteristics.isLocal,
              characteristics.isReadOnly,
              characteristics.isEjectable,
              characteristics.isRemovable else {
            return false
        }

        let cacheKey = values.volumeIdentifier.map {
            "\(volumeURL.path)|\(String(describing: $0))"
        }
        if let cacheKey, let cachedResult = cachedResults[cacheKey] {
            return cachedResult
        }

        let result = inspectInstallerLayout(at: volumeURL, characteristics: characteristics)
        if let cacheKey {
            cachedResults[cacheKey] = result
        }
        return result
    }

    private func inspectInstallerLayout(
        at volumeURL: URL,
        characteristics: InstallerVolumeCharacteristics
    ) -> Bool {
        let itemKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: volumeURL,
            includingPropertiesForKeys: itemKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var containsAppBundle = false
        var symlinkDestinations: [String] = []

        for item in items {
            let values = try? item.resourceValues(forKeys: Set(itemKeys))
            if values?.isDirectory == true,
               item.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                containsAppBundle = true
            }

            guard values?.isSymbolicLink == true,
                  let destination = try? fileManager.destinationOfSymbolicLink(atPath: item.path) else {
                continue
            }

            let resolvedDestination: URL
            if destination.hasPrefix("/") {
                resolvedDestination = URL(fileURLWithPath: destination)
            } else {
                resolvedDestination = item.deletingLastPathComponent()
                    .appendingPathComponent(destination)
            }
            symlinkDestinations.append(resolvedDestination.standardizedFileURL.path)
        }

        // Drag-to-install layouts sometimes give the /Applications symlink a
        // blank or single-space name so Finder can position it visually. Check
        // the destination instead of assuming the item is named "Applications".
        return DragToInstallVolumePolicy.shouldHideBar(
            characteristics: characteristics,
            containsAppBundle: containsAppBundle,
            symlinkDestinations: symlinkDestinations
        )
    }
}
