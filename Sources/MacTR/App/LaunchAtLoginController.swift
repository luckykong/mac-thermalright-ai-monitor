// LaunchAtLoginController.swift — SMAppService state shared by Settings and the menu bar

import Foundation
import Observation
import ServiceManagement

@Observable
@MainActor
final class LaunchAtLoginController {
    private let availabilityOverride: Bool?
    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var errorMessage: String?

    var isAvailable: Bool {
        availabilityOverride ?? (Bundle.main.bundleURL.pathExtension == "app")
    }

    init(availabilityOverride: Bool? = nil) {
        self.availabilityOverride = availabilityOverride
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        guard isAvailable else {
            errorMessage = "Launch at Login is available in the packaged MacTR.app."
            refresh()
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
            log("[Settings] Launch at login failed: \(error.localizedDescription)")
        }

        refresh()
    }

    func localizedErrorMessage(language: AppLanguage) -> String? {
        guard let errorMessage else { return nil }
        if errorMessage == "Launch at Login is available in the packaged MacTR.app." {
            return language.text(.packagedAppOnly)
        }
        // ServiceManagement errors are supplied by macOS and already follow the
        // user's system language, so preserve them verbatim.
        return errorMessage
    }
}
