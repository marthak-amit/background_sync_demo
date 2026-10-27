# RELIABILITY

**Nothing below has been measured yet.** I could not run on a physical Android or iOS device from the build
environment, so the *Measured* columns are intentionally blank rather than filled with guesses. The
*Expected* columns are design targets for the stacked layers, not results.

## Method
For each platform and each state, start sync, put the device in that state for **60 minutes**, then export
`devices/<id>` from the Realtime Database console and run:

```bash
node tools/analyze_gaps.js export.json --from <startMs> --to <endMs>   # --ontime 75 is the default threshold
```

* **Max gap** = largest difference between consecutive `clientTime` values (recomputed, not trusted from `gapSeconds`).
* **% on-time** = share of intervals ≤ 75 s (60 s + 15 s tolerance). Expected writes in 60 min ≈ 60.
* Use a fresh install, battery > 50 %, Wi-Fi, device not charging, a full 60 min per cell.
* Record device model / OS version / OEM skin next to each result: OEM skins dominate the Android variance.

## Android

| State | Expected max gap | Expected % on-time | Measured max gap | Measured % on-time | Notes |
|---|---|---|---|---|---|
| Foreground | ≤ 65 s | ≥ 99 % | | | |
| Background (home, screen on) | ≤ 65 s | ≥ 99 % | | | |
| Screen locked, plugged in | ≤ 65 s | ≥ 98 % | | | |
| Screen locked, on battery, 60 min (light Doze) | ≤ 75 s | ≥ 95 % | | | exact + alarm-clock alarms and the wake lock keep it awake |
| `dumpsys deviceidle force-idle` (deep Doze) | ≤ 90 s | ≥ 90 % | | | battery-optimisation exemption required; check alarm-clock layer |
| Swipe from recents | ≤ 5 s extra | ≥ 98 % | | | `stopWithTask=false` + restart alarm |
| `adb shell am kill` | ≤ 70 s | ≥ 95 % | | | START_STICKY, alarm watchdog, FCM |
| Reboot (after first unlock) | until boot + unlock | n/a | | | BootReceiver; Android 14+ may delay |
| Settings → Force Stop | **sync stops** | 0 % | | | see "Known blockers" |

## iOS

| State | Expected max gap | Expected % on-time | Measured max gap | Measured % on-time | Notes |
|---|---|---|---|---|---|
| Foreground | ≤ 65 s | ≥ 99 % | | | |
| Background (home, screen on) | ≤ 65 s | ≥ 98 % | | | location + audio keep-alive |
| Screen locked 60 min | ≤ 70 s | ≥ 95 % | | | needs Always location |
| Swipe-kill | ≤ 70 s via VoIP; minutes via region/significant change | VoIP ≥ 90 %, location-only ≪ | | | VoIP push is the only per-minute wake after kill |
| Reboot (after first unlock) | until unlock | n/a | | | keychain/UserDefaults unreadable before first unlock |
| Low Power Mode | unreliable | | | | see "Known blockers" |
| Background App Refresh off | BGTask layer dead; others live | | | | see "Known blockers" |

## Known blockers (documented only; they do not block the build)

### Android: Settings → Force Stop
After a force stop (Settings → App info → Force stop, or `adb shell am force-stop`), Android puts the
package into the *stopped* state: all alarms, jobs, WorkManager work and services are cancelled and **no broadcast
(including FCM and BOOT_COMPLETED) is delivered** until the user opens the app again. No code can
survive this. The same effect is produced by aggressive OEM "clean up / freeze" features and by some
vendors' swipe-away behaviour (Xiaomi, Oppo, Vivo, Huawei, Honor).

Mitigations the app shows / documents:
1. Checklist row *OEM auto-start / background* opens the vendor's auto-start screen; the user must enable it and set the app's battery mode to *No restrictions*.
2. Checklist row *Ignore battery optimisation* (exempts from Doze network/CPU limits and App Standby).
3. Persistent "Sync running" notification (the foreground service is what OEM killers spare most often).
4. Lock the app in the Recents screen (Xiaomi, Oppo, Vivo, Huawei, Samsung "Never sleeping apps").
5. Do not use "Force stop"; if the app is force-stopped, open it once and tap **Start sync**.
6. Exact-alarm access (Android 12–12L) and notifications are checklist items, so the watchdog and notification are not silently disabled.

### iOS: Low Power Mode and Background App Refresh off
* **Low Power Mode** suspends background fetch, BGTasks and mail fetch, and the system aggressively suspends
  background apps. Continuous location and audio usually still run, but iOS may stop the app anyway. The
  checklist shows a red *Low Power Mode off* row; the user must turn it off (Settings → Battery).
* **Background App Refresh off** (globally, or for this app) disables `BGAppRefreshTask`/`BGProcessingTask` and
  silent-push delivery. The checklist shows a red *Background App Refresh* row with the path
  Settings → General → Background App Refresh → ON. The location, audio and VoIP layers are independent of it.
* Other iOS limits to expect: the user force-quitting the app stops silent pushes and BGTasks (VoIP push and
  location relaunch still work); the system can revoke "Always" location or the VoIP token; devices that have
  not been unlocked since boot cannot read the keychain/Application Support data (writes wait until first unlock).

## Results summary (fill in after testing)

| Platform | Date | Device / OS | Worst state | Max gap | Overall % on-time | Verdict |
|---|---|---|---|---|---|---|
| Android | | | | | | |
| iOS | | | | | | |
