import PushKit
import CallKit

/// Layer 5: PushKit VoIP push. iOS terminates apps that receive a VoIP push without reporting a call,
/// so we report a CallKit incoming call and end it immediately, then write and restart the layers.
final class VoipPushHandler: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
    static let shared = VoipPushHandler()

    private var registry: PKPushRegistry?
    private lazy var provider: CXProvider = {
        let c = CXProviderConfiguration()
        c.supportsVideo = false
        c.maximumCallGroups = 1
        c.maximumCallsPerCallGroup = 1
        c.supportedHandleTypes = [.generic]
        let p = CXProvider(configuration: c)
        p.setDelegate(self, queue: nil)
        return p
    }()

    var hasToken: Bool { SyncStore.shared.voipToken != nil }

    /// Must run at every launch (AppDelegate.didFinishLaunching) so a killed app can be woken.
    func register() {
        guard Config.VOIP_ENABLED, registry == nil else { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = self
        r.desiredPushTypes = [.voIP]
        registry = r
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        SyncManager.shared.saveVoipToken(token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        // 1. Report a call synchronously (mandatory), 2. end it at once, 3. do the real work.
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Sync")
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            if SyncStore.shared.running {
                SyncManager.shared.restartLayers()
                SyncManager.shared.writeTick("push_wake") { completion() }
            } else {
                completion()
            }
        }
    }

    func providerDidReset(_ provider: CXProvider) {}
}
