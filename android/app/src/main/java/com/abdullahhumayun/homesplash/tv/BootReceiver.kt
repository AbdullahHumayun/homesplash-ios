package com.abdullahhumayun.homesplash.tv

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Opens the dashboard when the TV boots (if enabled in the setup dialog).
 * On Android 10+ launching an activity from the background needs the
 * "Display over other apps" permission — see the README for the one-time adb command.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != "android.intent.action.QUICKBOOT_POWERON") return
        val prefs = context.getSharedPreferences(MainActivity.PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(MainActivity.KEY_BOOT, true)) return
        context.startActivity(
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
