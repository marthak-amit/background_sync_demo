import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, MessagingDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SyncManager.shared.configureFirebase()
    if FirebaseApp.app() != nil { Messaging.messaging().delegate = self }
    // These two MUST be set up before launch finishes or a killed app cannot be woken by them.
    BGTasks.register()
    VoipPushHandler.shared.register()

    // Layer 4c: relaunched by the system because of a location event (significant change / region exit).
    let relaunchedByLocation = launchOptions?[.location] != nil
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if SyncStore.shared.running {
      SyncManager.shared.startAll(initialState: relaunchedByLocation ? "killed_relaunch" : nil)
    }
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ChannelBridge.shared.setup(messenger: engineBridge.applicationRegistrar.messenger())
  }

  // Layer 6: silent FCM push (content-available:1).
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    if FirebaseApp.app() != nil { Messaging.messaging().apnsToken = deviceToken }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    guard SyncStore.shared.running else { completionHandler(.noData); return }
    SyncManager.shared.restartLayers()
    SyncManager.shared.writeTick("push_wake") { completionHandler(.newData) }
  }

  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    if let t = fcmToken { SyncManager.shared.saveFcmToken(t) }
  }
}
