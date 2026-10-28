import SwiftUI
import UIKit
import UserNotifications

@main
struct TabTermApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        #if DEBUG
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        let demo = false
        #endif
        let model = AppModel(demo: demo)
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(TerminalTheme.claude)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

/// UIKit's half of the app: push registration and notification taps, which
/// SwiftUI has no hooks for.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var model: AppModel?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Already paired and already allowed: re-register every launch, since
        // tokens change (restores, reinstalls) and the Mac needs the current one.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { Self.model?.didRegisterForPush(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Nothing to do: without a token the Mac simply can't notify us.
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let session = response.notification.request.content.userInfo["session"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Self.model?.handleNotification(session: session) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let session = notification.request.content.userInfo["session"] as? String
        DispatchQueue.main.async {
            let show = MainActor.assumeIsolated { Self.model?.shouldPresentNotification(session: session) ?? true }
            completionHandler(show ? [.banner, .sound, .list] : [])
        }
    }
}
