import AppKit
import SwiftUI

enum AssistantPresence {
    static let windowID = "assistant"
    static let activationPolicy = NSApplication.ActivationPolicy.accessory
    static let terminateAfterLastWindowClosed = false
}

struct AssistantMenu: View {
    @ObservedObject var model: MeetingModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show assistant") { showAssistant() }
        Button("Settings…") {
            showAssistant()
            model.showSettings = true
        }
        Button("Refresh latest answer") { model.refreshSession() }
        Button("Reconnect audio and recover queue") { model.recoverSession() }
        Button("Show solid window") { model.setWindowTransparency(0) }
        Button("Stop listening") { model.stop() }.disabled(!model.listening && !model.connecting)
        Divider()
        Button("Quit Meetly") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func showAssistant() {
        openWindow(id: AssistantPresence.windowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
