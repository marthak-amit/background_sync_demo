package com.demo.background_sync_demo

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build

/** Known OEM auto-start / battery-protection screens. We try them in order and use the first that launches. */
object OemIntents {
    private data class Target(val pkg: String, val cls: String)

    private val byManufacturer: Map<String, List<Target>> = mapOf(
        "xiaomi" to listOf(
            Target("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
            Target("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"),
        ),
        "oppo" to listOf(
            Target("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            Target("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
            Target("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
            Target("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
        ),
        "realme" to listOf(
            Target("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
            Target("com.oplus.battery", "com.oplus.powermanager.fuelgaue.PowerConsumptionActivity"),
            Target("com.coloros.oppoguardelf", "com.coloros.powermanager.fuelgaue.PowerUsageModelActivity"),
        ),
        "vivo" to listOf(
            Target("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            Target("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
            Target("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
        ),
        "oneplus" to listOf(
            Target("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
            Target("com.oplus.battery", "com.oplus.powermanager.fuelgaue.PowerConsumptionActivity"),
        ),
        "samsung" to listOf(
            Target("com.samsung.android.lool", "com.samsung.android.sm.battery.ui.BatteryActivity"),
            Target("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"),
            Target("com.samsung.android.sm_cn", "com.samsung.android.sm.ui.battery.BatteryActivity"),
        ),
        "huawei" to listOf(
            Target("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            Target("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
            Target("com.huawei.systemmanager", "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"),
        ),
        "honor" to listOf(
            Target("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
            Target("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        ),
    )

    fun manufacturer(): String = Build.MANUFACTURER.lowercase()

    fun hasKnownTarget(): Boolean = byManufacturer.containsKey(manufacturer())

    /** @return the "pkg/class" that opened, or null if none of the known intents exist on this device. */
    fun open(ctx: Context): String? {
        val targets = byManufacturer[manufacturer()] ?: return null
        for (t in targets) {
            try {
                val i = Intent().setComponent(ComponentName(t.pkg, t.cls)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(i)
                return "${t.pkg}/${t.cls}"
            } catch (_: Exception) { /* try the next one */ }
        }
        return null
    }
}
