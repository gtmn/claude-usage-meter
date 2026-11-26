import AppKit
import UserNotifications

/// "Notify when signed out" (on by default): one macOS notification when Claude Code's login can't
/// come back without signing in again (`UsageModel.signedOut`), with a Sign in… button that does what
/// the popup's does. Once per sign-out, also across restarts (`LoginNudge.noticeStep`); signing in
/// again takes it out of Notification Centre. macOS asks for permission the first time one is due.
@MainActor
final class SignInNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SignInNotifier()
    static let enabledKey = "notifySignedOut"
    private static let notifiedKey = "signedOutNotified"
    nonisolated private static let id = "signed-out"
    nonisolated private static let category = "signed-out"
    nonisolated private static let signInAction = "sign-in"

    /// Runs Sign in… for the notification's button.
    private weak var model: UsageModel?

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    func start(model: UsageModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let signIn = UNNotificationAction(identifier: Self.signInAction, title: "Sign in…", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [signIn],
                                                                 intentIdentifiers: [])])
    }

    /// After each fetch: posts the notification when a sign-out begins, clears it when it ends.
    func update(signedOut: Bool, savedAt: Date?) {
        let defaults = UserDefaults.standard
        let wasNotified = defaults.bool(forKey: Self.notifiedKey)
        let step = LoginNudge.noticeStep(signedOut: signedOut, notified: wasNotified, enabled: Self.enabled)
        if step.notified != wasNotified { defaults.set(step.notified, forKey: Self.notifiedKey) }
        if step.post { Self.post(LoginNudge.signedOutNotice(savedAt: savedAt)) }
        if wasNotified && !signedOut {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.id])
        }
    }

    nonisolated private static func post(_ notice: (title: String, body: String), done: (@Sendable (String) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            guard granted else {
                let why = "notification: not allowed" + (error.map { " (\($0.localizedDescription))" } ?? "")
                AppLog.write(why); done?(why); return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.categoryIdentifier = category
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                let result = error.map { "notification: failed (\($0.localizedDescription))" } ?? "notification: signed out"
                AppLog.write(result); done?(result)
            }
        }
    }

    /// Shown even though the app counts as active while its popup is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.signInAction {
            Task { @MainActor in SignInNotifier.shared.model?.startSignIn() }
        }
        completionHandler()
    }

    /// `UsageMeter --test-notification`: posts the notification once, with numbers from an hour ago
    /// (asking for permission if macOS hasn't yet), prints what happened and exits.
    nonisolated static func testFromCommandLine() -> Never {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = "notification: no answer"
        post(LoginNudge.signedOutNotice(savedAt: Date().addingTimeInterval(-3600))) { r in result = r; sem.signal() }
        _ = sem.wait(timeout: .now() + 120)
        print(result)
        exit(result == "notification: signed out" ? 0 : 1)
    }
}
