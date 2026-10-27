# Background Sync Demo (Flutter, Android + iOS)

Demo build that tries to write `Test_{n}` to Cloud Firestore **every 60 s in every app state**
(foreground, background, screen locked, killed), by stacking every wake mechanism the two OSes offer.
**Store-policy compliance is not a goal** (continuous location, silent audio, and VoIP/CallKit as a wake trick
would all be rejected in review). Reliability is.

> **Status.** The Android release APK builds (`flutter build apk --release`), the Cloud Functions compile
> (`npm run build`) and the analysis script is tested. The Android layers have **not** been run on a device
> and the iOS code has **not** been compiled (it needs macOS/Xcode). Nothing in this repo has measured gaps
> yet; run the tests in [RELIABILITY.md](RELIABILITY.md) and fill in the table.

## Architecture

The app also lets the user **pick an image, type text and submit**; the post (and image, in Cloud Storage) is queued
on the device and uploaded as soon as a network exists, in every app state (see *User posts* below). Flutter is UI only. Timers and Firebase writes run in Kotlin / Swift using the native Firebase SDKs, so they
keep working while the Flutter engine is paused or not running. Flutter talks to native over
`MethodChannel("sync/control")` (start / stop / status / permissions / fix) and
`EventChannel("sync/logs")` (live last-30 records). Flutter needs no Firebase plugin and no
`firebase_options.dart`, so `flutterfire configure` is not required (it only generates a Dart file nothing uses).

Every layer calls one function, `SyncManager.writeTick(appState)` (`SyncManager.kt` / `SyncManager.swift`):

1. Skip if the last write was < 55 s ago (`Config.DEDUPE_MS`), the same check for every wake path.
2. `n = lastN + 1`, persisted locally (`SharedPreferences` / `UserDefaults`) **before** anything is sent.
3. Insert into a local **SQLite queue** with a pre-generated push key (retries are idempotent).
4. Flush the queue in order; one Firestore batch writes `devices/{id}/logs/{id}` + merges `lastN, lastWriteAt, platform, fcmToken[, voipToken]`
   into the device document `devices/{id}`. Offline: the row stays queued and is flushed when a network returns. Firestore's persistent cache is also enabled.
5. On every start `reconcile()` runs a transaction on `devices/{id}.lastN` setting it to `max(remote, local)`.

Record: `{value, n, platform, appState, deviceId, clientTime, timestamp (server), gapSeconds}`.
Firestore has no `meta` sibling of a document, so the per-device meta fields live on the device document itself
(`devices/{id}`), with `logs` and `posts` as its subcollections.
`deviceId` is the anonymous-auth uid, which is what the security rules key on.
`appState` is one of `foreground | background | killed_relaunch | push_wake | bg_task`.

### Android layers
| # | Layer | Where |
|---|-------|-------|
| 1 | Foreground service, `foregroundServiceType="dataSync"`, 60 s fixed-rate loop on a HandlerThread, "Sync running" notification | `SyncService.kt` |
| 2 | Partial wake lock per write (30 s timeout). Extra: a self-expiring wake lock renewed every tick (`Config.CONTINUOUS_WAKELOCK`) | `SyncManager.kt`, `SyncService.kt` |
| 3 | `stopWithTask="false"`, `START_STICKY`, `onTaskRemoved`/`onDestroy` schedule a 1 s restart alarm | `SyncService.kt`, `Scheduler.kt` |
| 4 | `setExactAndAllowWhileIdle` every 60 s that also writes directly (`bg_task`) and restarts the service. Extra: a second `setAlarmClock` alarm, exempt from Doze throttling (`Config.USE_ALARM_CLOCK`) | `Scheduler.kt`, `Receivers.kt` |
| 5 | `BOOT_COMPLETED` + `MY_PACKAGE_REPLACED` receiver | `Receivers.kt` |
| 6 | WorkManager 15 min periodic restarter | `Scheduler.kt`, `Receivers.kt` |
| 7 | FCM high-priority data message every minute from the Cloud Function | `FcmService.kt` |
| 8 | Onboarding checklist: notifications, battery-optimisation exemption, exact alarms, OEM auto-start deep links (Xiaomi, Oppo, Realme, Vivo, OnePlus, Samsung, Huawei, Honor) | `MainActivity.kt`, `OemIntents.kt` |

Design notes: `targetSdk` is **34** on purpose. On targetSdk 35 Android 15 limits `dataSync` services to 6 h per
24 h and blocks them from `BOOT_COMPLETED`. `USE_EXACT_ALARM` is declared for API 33+ (auto-granted, which
Play would restrict); `SCHEDULE_EXACT_ALARM` covers API 31–32. If the OS refuses to start the service from the
background, the alarm / WorkManager / FCM layers still call `writeTick` directly.

### iOS layers
| # | Layer | Where |
|---|-------|-------|
| 1 | `CLLocationManager`: Always, `allowsBackgroundLocationUpdates`, no auto-pause, background indicator, 3 km accuracy, no distance filter; keeps the process alive so the 60 s `Timer` (`RunLoop .common`) fires | `LocationKeepAlive.swift`, `SyncManager.swift` |
| 2 | `AVAudioSession .playback + .mixWithOthers`, looping generated silent WAV (`Config.AUDIO_ENABLED`, default on) | `SilentAudio.swift` |
| 3 | Every write wrapped in `beginBackgroundTask`/`endBackgroundTask` | `SyncManager.writeTick` |
| 4 | Relaunch after kill: (a) significant-change monitoring, (b) 100 m `CLCircularRegion` re-armed on every wake, (c) `launchOptions[.location]` → `writeTick("killed_relaunch")` + restart layers 1–3 | `LocationKeepAlive.swift`, `AppDelegate.swift` |
| 5 | PushKit VoIP push → report CallKit call and end it immediately → `writeTick("push_wake")` → restart layers (`Config.VOIP_ENABLED`, default on) | `VoipPushHandler.swift` |
| 6 | Silent FCM (`content-available:1`, `apns-push-type: background`, priority 5) → `push_wake` | `AppDelegate.swift` |
| 7 | `BGAppRefreshTask` + `BGProcessingTask`, rescheduled on every run → `bg_task` | `BackgroundTasks.swift` |
| 8 | Info.plist: `UIBackgroundModes` = location, audio, fetch, processing, remote-notification, voip; location usage strings; `BGTaskSchedulerPermittedIdentifiers` | `Info.plist` |
| 9 | Entitlement `aps-environment`; Background Modes are the plist keys above | `Runner.entitlements` |

## User posts (image + text, offline-first)

UI → **Pick image** (gallery, compressed to ≤1600 px / quality 80) → type text → **Submit**. Image is optional.

1. `submitPost` copies the image into an app-private outbox and inserts a row in the same SQLite database as the heartbeat queue. Nothing is sent yet, so it works with no connectivity.
2. The post is uploaded by the same machinery as the heartbeat, in the same order of precedence:
   immediately if online; on the next 60 s tick (every wake path, including deduped ones); the moment a network appears
   (Android `NetworkCallback` + WorkManager `CONNECTED` job, iOS `NWPathMonitor`); and on every relaunch.
3. Upload = image to Storage `devices/{id}/images/{postId}.jpg` (100 s timeout; once uploaded the URL is stored so it is never re-uploaded),
   then Firestore `devices/{id}/posts/{postId} = {text, imagePath, imageUrl, clientTime, timestamp, deviceId, platform}`. Fixed ids make retries idempotent.
4. The "Waiting to upload" list shows queued posts with a `queued` badge; synced posts show a cloud-done icon.

**Background / suspended / killed:** posts ride on the same layers as the heartbeat, so tap **Start sync**. On Android, a queued post is also
guaranteed an upload by a persistent WorkManager job even if sync is stopped (not after Force Stop; see managed devices). On iOS, uploads happen while the
keep-alive layers run or after one of the relaunch paths wakes the app (location, VoIP, silent push, BGTask), and iOS gives a woken app limited time,
so very large images on a poor link may need a later wake: images are compressed to keep uploads short.

## Offline and "must not lose data" behaviour

Remote units will often have no connectivity. Writes are therefore **never dependent on the network**:
every tick is persisted (counter + SQLite row) before any network call, so nothing is lost while offline.

* No network → the tick is queued and returns immediately (no 20 s stall per tick).
* The moment any network appears the queue is flushed in order, by three independent triggers:
  Android `NetworkCallback` in the service, a WorkManager job with a `CONNECTED` constraint (survives the service
  dying and reboots), and the next tick; iOS `NWPathMonitor` (inside a background task) and the next tick.
* Push keys are generated at write time, so a retried flush is idempotent (no duplicates), and `n` never repeats.
* `clientTime` is the real capture time; `timestamp` is the server time at upload (later when it was queued).
  The UI and `analyze_gaps.js` use `clientTime`.

## Surviving what the OS tries to block

| Blocker | Can an app defeat it? | What this repo does |
|---|---|---|
| Android **Force Stop** / Clear data | **Only on a managed device.** Stopped packages receive no alarms, jobs, services, broadcasts or FCM, so no app code can survive it. | **Device-owner mode** (below) greys out Force Stop and Clear data for the app. Elsewhere: `ExitReasons` writes `lastExit = USER_REQUESTED_FORCE_STOP@…` on the device document on the next start, the checklist shows a red row, and `staleDeviceAlert` notifies the user. |
| iOS **Low Power Mode** | No. Only the user can change it. | Layers that LPM leaves running (location, audio, VoIP, timer) stay on; `Degradation.swift` posts a local notification the moment it turns on, shows a red checklist row, and reports `lowPowerMode`. |
| iOS **Background App Refresh off** | No. | It only disables the BGTask and silent-push layers; location, audio and VoIP do not use it. Same alert + `bgRefresh`. |
| iOS user force-quits | Partly | VoIP push + location relaunch still wake the app. |

`staleDeviceAlert` (Cloud Function, every 5 min) sends a visible notification to any device that has not written
for 3 min, with the specific instruction (turn off Low Power Mode / enable Background App Refresh / reopen after force stop).

### Managed devices (Android Force Stop lock)
For remote units you control, make the app the **device owner**. The app then calls
`setUserControlDisabledPackages` (Android 11+), which disables *Force stop* and *Clear data* for it, and pre-grants the notification permission.
Choose one provisioning route:

* **Fresh or factory-reset device, over USB (no accounts may be signed in):**
  ```bash
  adb install -r build/app/outputs/flutter-apk/app-release.apk
  adb shell dpm set-device-owner com.demo.background_sync_demo/.SyncDeviceAdminReceiver
  ```
  Open the app: the checklist row *Managed device (Force Stop locked)* turns green.
* **Fleet:** provision with a QR code / zero-touch / any EMM that can set this component as device owner
  (`com.demo.background_sync_demo/.SyncDeviceAdminReceiver`, APK served from a URL).
* To undo: `adb shell dpm remove-active-admin com.demo.background_sync_demo/.SyncDeviceAdminReceiver` (a factory reset otherwise).

This does not stop the user from powering the phone off, uninstalling (device owner can also block that via an EMM), or a vendor "app cleaner".

## Setup

Prerequisites: Flutter (stable), Android SDK / JDK 17, Xcode + CocoaPods (iOS), Node 22 + Firebase CLI.

### 1. Firebase project
1. Create a project (the demo uses `test-back-sync`) and enable: **Authentication → Anonymous**, **Cloud Firestore** (create the database in production mode; the rules below lock it down) and **Storage**. Storage and Cloud Functions require the **Blaze** plan.
2. Add an Android app `com.demo.background_sync_demo` and an iOS app `com.demo.backgroundSyncDemo`.
3. Put the files in place (git-ignored; download them from the Firebase console for project `test-back-sync`):
   - `android/app/google-services.json`
   - `ios/Runner/GoogleService-Info.plist` (a build phase copies it into the app bundle; nothing to drag in Xcode)
4. Deploy the rules: `firebase deploy --only firestore,storage`
   (`firestore.rules` / `storage.rules`: a device can read/write only `devices/{its own uid}` and `devices/{its own uid}/images/*`). `.firebaserc` already points at `test-back-sync`.
5. If you use different bundle / package ids, change them in the Android `applicationId`, the Xcode bundle id,
   and `BGTaskSchedulerPermittedIdentifiers` / `Config.swift` / `APNS_BUNDLE_ID` (they must all agree).

### 2. APNs key and VoIP (iOS only)
A single **APNs Auth Key (.p8)** covers regular, silent and VoIP pushes, so no separate VoIP certificate is needed.
1. Apple Developer → Keys → create a key with **Apple Push Notifications service (APNs)**; download `AuthKey_<KEYID>.p8`; note the Key ID and your Team ID.
2. Firebase console → Project settings → Cloud Messaging → *Apple app configuration* → upload the same `.p8` (Key ID + Team ID). This is for the silent FCM layer.
3. Xcode → Runner target → *Signing & Capabilities*: pick your team, make sure **Push Notifications** and **Background Modes** (Location updates, Audio, Background fetch, Background processing, Remote notifications, Voice over IP) are present. The entitlement and plist keys are already in the repo; Xcode just has to register them with your provisioning profile.
4. Store the key for the Cloud Function (Secret Manager, never in code):
   ```bash
   firebase functions:secrets:set APNS_KEY_P8 < AuthKey_XXXXXXXXXX.p8
   ```
   If you run Android only, set it to any placeholder; VoIP pushes are skipped when no device has a `voipToken`.
   (If you specifically want legacy VoIP *certificate* auth, it is not implemented; the `.p8` path is the supported one.)

### 3. Cloud Functions (needs the Blaze plan)
Scheduled functions (Cloud Scheduler), Secret Manager and outbound calls to APNs all require the **Blaze (pay-as-you-go)** plan.
At 1 invocation/minute for a few devices the cost is normally cents per month, but it is not free-tier.
```bash
cd functions && npm install && cd ..
firebase deploy --only functions,firestore,storage
# at deploy time you are asked for: APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_SANDBOX
```
Use `APNS_SANDBOX=true` for builds run from Xcode (development provisioning), `false` for TestFlight / ad-hoc / production.
`syncTick` runs every minute: for each `devices/*/meta` it sends an Android high-priority FCM data message, an iOS silent
FCM push, and an iOS VoIP push (HTTP/2 + JWT signed with the `.p8`). Dead tokens are deleted from `meta`.

### 4. Install and run
```bash
flutter pub get
flutter build apk --release && adb install -r build/app/outputs/flutter-apk/app-release.apk
flutter build ios --release --no-codesign   # macOS only; then sign/run from Xcode (run `pod install` in ios/ first)
```
Open the app → fix every red row in the checklist → **Start sync**.

## Granting permissions

**Android** (checklist rows have a *Fix* button):
- *Notifications* (Android 13+): accept the prompt.
- *Ignore battery optimisation*: accept the system dialog (or Settings → Apps → Background Sync Demo → Battery → Unrestricted).
- *Exact alarms* (Android 12–12L only; 13+ is automatic): toggle "Alarms & reminders".
- *OEM auto-start*: the button opens the vendor screen (Xiaomi Autostart, Oppo/Realme Startup manager, Vivo Background startup, OnePlus Chain launch, Samsung Battery → "Never sleeping apps", Huawei/Honor Startup manager). Enable auto-start, set battery to *No restrictions*, and lock the app in Recents. Android cannot report this setting, so the row turns green once you have opened the screen.

**iOS**:
- *Location*: choose **Allow While Using**, then accept the second prompt for **Always** (or Settings → Privacy → Location Services → app → Always). Keep *Precise* on or off, either works.
- *Background App Refresh*: Settings → General → Background App Refresh → ON (globally and for the app).
- *Low Power Mode*: OFF.
- Leave the app's blue location indicator alone and do not force-quit unless you are testing the kill path.

## How to test each state

**Android**
```bash
PKG=com.demo.background_sync_demo
adb logcat -s SyncManager SyncService Scheduler AlarmReceiver FcmService       # watch ticks
adb shell dumpsys deviceidle force-idle                                        # deep Doze (then: adb shell dumpsys deviceidle unforce)
adb shell dumpsys battery unplug; adb shell dumpsys deviceidle enable          # make Doze reachable on USB
adb shell am kill $PKG                                                         # kill the cached process (service should come back)
adb shell am force-stop $PKG                                                   # = Settings force stop; NOTHING restarts after this (see RELIABILITY.md)
# swipe from recents, screen off 1 h, or `adb reboot` then unlock once
```
Expect `killed_relaunch` as the first tag after a restart, `bg_task` from alarm/WorkManager writes, `push_wake` from FCM.

**iOS**
- Lock the screen for 1 h with the app started; swipe-kill; reboot (unlock once, then wait).
- Xcode → Debug → *Simulate Background Fetch* (BGAppRefresh path) and *Simulate Location* / a custom GPX (region / significant-change path).
- Force BG tasks from the debugger: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.demo.backgroundSyncDemo.refresh"]`
- VoIP and silent FCM need a **real device** (the simulator has no APNs tokens).

**Measure**: export the logs and analyse them (needs a service-account key; see the header of the script):
```bash
node tools/export_logs.js                       # list device ids
node tools/export_logs.js <deviceId> export.json
node tools/analyze_gaps.js export.json --from <startMs> --to <endMs>   # per-state max gap and % on time
```

## Layout
```
lib/main.dart                      UI only
android/app/src/main/kotlin/...    SyncManager, SyncService, Scheduler, Receivers, FcmService, OemIntents, MainActivity
ios/Runner/Sync/*.swift            SyncManager, LocationKeepAlive, SilentAudio, VoipPushHandler, BackgroundTasks, ChannelBridge
ios/Runner/AppDelegate.swift       launch detection, BG task / PushKit registration, silent push
functions/src/index.ts             syncTick (FCM + APNs VoIP)
firestore.rules  storage.rules  firebase.json
tools/export_logs.js, analyze_gaps.js   export Firestore logs + gap statistics for RELIABILITY.md
```
