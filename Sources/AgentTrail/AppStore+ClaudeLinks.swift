import AppKit
import Foundation
import os

/// "Open sessions in either instance": direct Claude links (see DirectLink).
extension AppStore {
    /// The ⋯ menu offers direct links with several Claude Desktop profiles, or
    /// several running Claude instances (one may have no profile), and keeps
    /// the switch reachable once it is on, so it can be turned off.
    var hasSeveralClaudeInstances: Bool {
        sources.filter { $0.assistant == .claude && $0.bundleIdentifier == SessionLauncher.claudeBundleID }.count > 1
            || SessionLauncher.runningClaudeCount > 1
            || AppSettings.directClaudeLinks
    }

    /// Where an access answer came from, which decides what is said about it.
    enum ClaudeLinkCheck {
        /// At launch or when the panel opens: only the menu changes.
        case quiet
        /// The switch was just turned on: the answer is confirmed either way.
        case toggle
        /// A Jump: its hint already names a denial; the panel adds why, once.
        case jump
    }

    static let claudeLinkDeniedMessage = "macOS doesn't let Agent Trail send links to Claude, so Jump shows a hint for the instance opened later. Turn on Claude under Agent Trail in System Settings › Privacy & Security › Automation."

    /// Records each answer a Jump gets, and checks quietly at launch when the switch is on.
    func observeClaudeLinkAccess() {
        SessionLauncher.claudeLinkPermissionAnswered = { [weak self] permission in
            self?.recordClaudeLinkAccess(permission, from: .jump)
        }
        if AppSettings.directClaudeLinks { checkClaudeLinkAccess(ask: false) }
    }

    /// Turning the switch on asks macOS right away when a Claude runs, so the
    /// prompt follows the click; otherwise it comes with the first Jump that needs it.
    func setDirectClaudeLinks(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: AppSettings.Key.directClaudeLinks)
        if on { checkClaudeLinkAccess(ask: true) }
    }

    /// Asks about the "open URL" event to a running Claude, off the main thread.
    /// Without `ask` it never prompts and sends nothing to Claude.
    func checkClaudeLinkAccess(ask: Bool) {
        guard let pid = SessionLauncher.anyClaudeProcess() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let permission = DirectLink.permission(for: pid, askIfNeeded: ask)
            DispatchQueue.main.async { [weak self] in
                self?.recordClaudeLinkAccess(permission, from: ask ? .toggle : .quiet)
            }
        }
    }

    /// Opens System Settings at Privacy & Security › Automation, where a denied
    /// answer can be changed. Agent Trail cannot change it itself.
    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func recordClaudeLinkAccess(_ permission: OSStatus, from check: ClaudeLinkCheck) {
        let answer = DirectLink.access(for: permission)
        let log = Logger(subsystem: "local.agenttrail.app", category: "jump")
        // Saved (notice) when the answer changes; the same answer again, as at
        // every panel open, stays in memory (info).
        if answer == claudeLinkAccess {
            log.info("Claude link access: permission \(permission, privacy: .public)")
        } else {
            log.notice("Claude link access: permission \(permission, privacy: .public)")
        }
        guard let access = answer else { return }
        let wasDenied = claudeLinkAccess == .denied
        claudeLinkAccess = access
        // Access allowed again in System Settings: the old explanation no longer holds.
        if access != .denied, errorMessage == Self.claudeLinkDeniedMessage { errorMessage = nil }
        switch (access, check) {
        case (.allowed, .toggle):
            let text = "Jump now opens sessions in either Claude instance"
            if isPanelVisible {
                errorMessage = nil
                infoMessage = text
            } else {
                HintHUD.show(text, symbol: "checkmark.circle")
            }
        case (.denied, .toggle):
            errorMessage = Self.claudeLinkDeniedMessage
            infoMessage = nil
            if !isPanelVisible {
                HintHUD.show("Turn on Claude under Agent Trail in System Settings › Automation",
                             symbol: "exclamationmark.triangle", duration: 5)
            }
        case (.denied, .jump) where !wasDenied:
            errorMessage = Self.claudeLinkDeniedMessage
            infoMessage = nil
        default:
            break
        }
    }
}
