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
| Settings → Force Stop (unmanaged) | **sync stops** | 0 % | | | see "Known blockers" |
| Force Stop attempt on device-owner install | button disabled; sync continues | ≥ 95 % | | | untested |
| Airplane mode 20 min, then online | all queued rows flushed in order | 100 % of `n` present | | | offline queue |

## iOS

| State | Expected max gap | Expected % on-time | Measured max gap | Measured % on-time | Notes |
|---|---|---|---|---|---|
| Foreground | ≤ 65 s | ≥ 99 % | | | |
| Background (home, screen on) | ≤ 65 s | ≥ 98 % | | | location + audio keep-alive |
| Screen locked 60 min | ≤ 70 s | ≥ 95 % | | | needs Always location |
| Swipe-kill | ≤ 70 s via VoIP; minutes via region/significant change | VoIP ≥ 90 %, location-only ≪ | | | VoIP push is the only per-minute wake after kill |
| Reboot (after first unlock) | until unlock | n/a | | | keychain/UserDefaults unreadable before first unlock |
| Low Power Mode | location/audio/VoIP expected to continue | | | | alert + `meta/lowPowerMode`; untested |
| Airplane mode 20 min, then online | all queued rows flushed in order | 100 % of `n` present | | | offline queue |
| Background App Refresh off | BGTask layer dead; others live | | | | see "Known blockers" |

## Known blockers and what the app does about them

These are OS rules. No code can override them on an ordinary device; the app removes what it can, detects the
rest, and tells the user. Items marked (untested) have not been run on hardware.

### Android: Settings → Force Stop
After a force stop the package is in the *stopped* state: alarms, jobs, WorkManager work and services are
cancelled and **no broadcast (including FCM and BOOT_COMPLETED) is delivered** until the user opens the app.
* **Eliminated on managed devices (untested):** install as device owner (README → *Managed devices*). The app then calls
  `setUserControlDisabledPackages`, so Force stop and Clear data are disabled for it in Settings. The checklist row
  *Managed device (Force Stop locked)* shows green when active.
* **Unmanaged devices:** cannot be prevented. Mitigations: (1) next start records `meta/lastExit =
  USER_REQUESTED_FORCE_STOP@<ms>` so the gap is explained in Firebase; (2) `staleDeviceAlert` queues a visible
  "Sync was force-stopped, open the app" notification; (3) the UI shows the red managed-device row.
* OEM killers (Xiaomi, Oppo, Vivo, Huawei, Honor, Samsung) behave like a force stop: use the *OEM auto-start* row,
  the *Ignore battery optimisation* row, the persistent "Sync running" notification, and lock the app in Recents.

### iOS: Low Power Mode and Background App Refresh off
* **Low Power Mode** (user setting, cannot be changed by an app): background fetch/BGTasks are suspended and iOS may
  suspend the app. Location and audio keep-alive, the 60 s timer and VoIP push are the layers expected to continue (untested).
  The app posts a local notification immediately when it is turned on, shows a red checklist row, and writes
  `meta/lowPowerMode`, which the server watchdog turns into "turn off Low Power Mode".
* **Background App Refresh off** disables BGTasks and silent push only. Location, audio and VoIP do not depend on it. Same
  notification / checklist / `meta/bgRefresh` handling.
* Not preventable on iOS at all: reboot-before-first-unlock (keychain/Application Support unreadable until unlock, writes
  resume after), user revoking Location "Always" (alert + `meta/locationAlways`), and the user force-quitting
  (silent push and BGTasks stop; VoIP push and location relaunch still work).

### No connectivity (both platforms)
Handled in code, not just documented: writes are queued locally and flushed in order on network return. Test: airplane
mode for 20 min in each state, then disable it; expect every missed `n` to appear with the correct `clientTime`, no duplicates
and no repeats. Record the result in the table above.

## Results summary (fill in after testing)

| Platform | Date | Device / OS | Worst state | Max gap | Overall % on-time | Verdict |
|---|---|---|---|---|---|---|
| Android | | | | | | |
| iOS | | | | | | |
