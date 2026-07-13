import SwiftUI

/// SwiftUI's entry point for the process.
///
/// The app has no ordinary document scene. `AppDelegate` owns the menu-bar app
/// lifecycle, while this empty Settings scene satisfies SwiftUI's scene model.
@main
struct FinderBreadcrumbsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
