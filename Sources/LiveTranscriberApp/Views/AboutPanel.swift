import AppKit

/// The standard About panel, driven by explicit options rather than whatever
/// AppKit infers: `swift run` has no Info.plist at all, and even in the
/// packaged app the inferred icon falls back to a generic one.
@MainActor
enum AboutPanel {
  static func show() {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
      .applicationName: AppInfo.name,
      .applicationVersion: AppInfo.version,
      // CFBundleVersion mirrors CFBundleShortVersionString, so the default
      // "(build)" parenthetical would just repeat the version.
      .version: "",
    ]
    if let icon = AppInfo.icon {
      options[.applicationIcon] = icon
    }
    NSApp.activate()
    NSApp.orderFrontStandardAboutPanel(options: options)
  }
}
