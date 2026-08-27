package com.example.lifeloop.ble

import android.app.Service
import android.content.Intent
import android.os.IBinder


class BleMonitorService : Service(){

    companion object {
        const val SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        const val CHARACTERISTIC_UUID_TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    }

    override fun onBind(intent: Intent?): IBinder? {
    // Not binding directly to an Activity, so return null
        return null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    // Entry point: Foreground notification & BLE scanning will start here
        return START_STICKY
    }
}