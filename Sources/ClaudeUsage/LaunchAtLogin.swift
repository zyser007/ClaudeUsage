import Foundation
import ServiceManagement
import Combine

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != wasEnabled else { return }
            apply(isEnabled)
        }
    }
    @Published private(set) var errorMessage: String?

    private var wasEnabled: Bool

    init() {
        let enabled = SMAppService.mainApp.status == .enabled
        isEnabled = enabled
        wasEnabled = enabled
    }

    private func apply(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            wasEnabled = enable
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            // Revert the toggle — the system rejected the change.
            wasEnabled = !enable
            isEnabled = !enable
        }
    }

    func refresh() {
        let enabled = SMAppService.mainApp.status == .enabled
        wasEnabled = enabled
        isEnabled = enabled
    }

    /// Prints the current status and exits, changing nothing. Scripts need to
    /// read the state without the side effects selfTest() has.
    nonisolated static func printStatus() -> Never {
        let s = SMAppService.mainApp.status
        switch s {
        case .notRegistered: print("notRegistered")
        case .enabled: print("enabled")
        case .requiresApproval: print("requiresApproval")
        case .notFound: print("notFound")
        @unknown default: print("unknown(\(s.rawValue))")
        }
        exit(0)
    }

    /// Exercises the real register/unregister path so the toggle can be
    /// verified without clicking it. Must run from inside the .app bundle.
    ///
    /// Restores whatever state it found. It used to end on unregister(), which
    /// silently switched Launch at Login off for anyone who had it on — a
    /// diagnostic that breaks the thing it inspects is worse than none.
    nonisolated static func selfTest() -> Never {
        func describe(_ s: SMAppService.Status) -> String {
            switch s {
            case .notRegistered: return "notRegistered"
            case .enabled: return "enabled"
            case .requiresApproval: return "requiresApproval (needs enabling in System Settings)"
            case .notFound: return "notFound"
            @unknown default: return "unknown(\(s.rawValue))"
            }
        }

        let service = SMAppService.mainApp
        let wasEnabled = service.status == .enabled
        print("bundle: \(Bundle.main.bundlePath)")
        print("before: \(describe(service.status))")

        do {
            try service.register()
            print("register(): ok -> \(describe(service.status))")
        } catch {
            print("register(): FAILED -> \(error.localizedDescription)")
            exit(1)
        }

        do {
            try service.unregister()
            print("unregister(): ok -> \(describe(service.status))")
        } catch {
            print("unregister(): FAILED -> \(error.localizedDescription)")
            exit(1)
        }

        if wasEnabled {
            do {
                try service.register()
                print("restored: \(describe(service.status)) (was enabled before this test)")
            } catch {
                print("restore FAILED -> \(error.localizedDescription)")
                print("Launch at Login is now OFF — re-tick it in the app.")
                exit(1)
            }
        }
        exit(0)
    }
}
