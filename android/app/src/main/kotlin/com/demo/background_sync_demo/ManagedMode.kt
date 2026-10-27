package com.demo.background_sync_demo

import android.Manifest
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.util.Log

/** Receiver required for device-owner provisioning (see README: "Managed devices"). */
class SyncDeviceAdminReceiver : DeviceAdminReceiver()

/**
 * The only way to survive Settings -> Force Stop (and Clear data) is for the app to be the device owner of a
 * managed device. When it is, we lock those controls for our own package and pre-grant permissions.
 * On a normal (unmanaged) device this is a no-op and the checklist shows the row as red.
 */
object ManagedMode {
    private const val TAG = "ManagedMode"

    fun isDeviceOwner(ctx: Context): Boolean =
        (ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager).isDeviceOwnerApp(ctx.packageName)

    /** True when Force Stop / Clear data are actually blocked for this package. */
    fun forceStopLocked(ctx: Context): Boolean {
        if (!isDeviceOwner(ctx)) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val dpm = ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val admin = ComponentName(ctx, SyncDeviceAdminReceiver::class.java)
        return try { dpm.getUserControlDisabledPackages(admin).contains(ctx.packageName) } catch (_: Exception) { false }
    }

    fun apply(ctx: Context) {
        if (!isDeviceOwner(ctx)) return
        val dpm = ctx.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        val admin = ComponentName(ctx, SyncDeviceAdminReceiver::class.java)
        try {
            // Android 11+: greys out Force stop and Clear data for this package in Settings.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                dpm.setUserControlDisabledPackages(admin, listOf(ctx.packageName))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                dpm.setPermissionGrantState(admin, ctx.packageName, Manifest.permission.POST_NOTIFICATIONS,
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED)
            }
            Log.i(TAG, "device-owner policies applied")
        } catch (e: Exception) {
            Log.w(TAG, "apply failed: ${e.message}")
        }
    }
}
