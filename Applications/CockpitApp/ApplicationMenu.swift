import AppKit

@MainActor
func makeCockpitMainMenu(
    application: NSApplication,
    applicationName: String
) -> NSMenu {
    let mainMenu = NSMenu()
    let applicationMenuItem = NSMenuItem()
    let applicationMenu = NSMenu(title: applicationName)
    applicationMenuItem.submenu = applicationMenu
    mainMenu.addItem(applicationMenuItem)

    let quitItem = NSMenuItem(
        title: "Quit \(applicationName)",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    quitItem.target = application
    quitItem.keyEquivalentModifierMask = [.command]
    applicationMenu.addItem(quitItem)
    return mainMenu
}
