import AppKit

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "Connecting…")
    private let viewModel = ServiceStatusViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cockpit"
        label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        Task { label.stringValue = await viewModel.statusText() }
    }
}
