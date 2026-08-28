// Background services: Android service that builds and holds notification channel.

package com.example.lifeloop.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.Intent
import android.os.IBinder
import com.example.lifeloop.R


class BleMonitorService : Service(){

    companion object {
        const val SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        const val CHARACTERISTIC_UUID_TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    }
    // 1. Manages all bluetooth operations on device
    //    By lazy allows for bluetooth radio to be powered on only when the scanner is called
    private val bluetoothManager by lazy {
        getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    }
    // 2. Represents physical bluetooth radio in phone
    private val bluetoothAdapter by lazy {
        bluetoothManager.adapter
    }

    // 3. The specific tool designed to scan for Low Energy (BLE) devices
    private val bleScanner by lazy {
        bluetoothAdapter.bluetoothLeScanner
    }

    // 4. The asynchronous callback trap that triggers when a device is found
    //    scanCallback runs on background thread, preventing a UI freeze/stutter
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            super.onScanResult(callbackType, result)
            // We will inspect "result.device" and extract the telemetry string here!
        }
    }


    override fun onBind(intent: Intent?): IBinder? {
    // Not binding directly to an Activity, so return null
        return null
    }



    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    // Entry point: Foreground notification & BLE scanning will start here
        // Unique string identifying specific category of notification
        val CHANNEL_ID = "LifeLoopChannel"
    // Human readable name that user will see in app settings
        val name = "BLE Monitoring Service"
    // Set importance as low in order to prevent user phone from vibrating
        val importance = NotificationManager.IMPORTANCE_LOW

    //Create usable object known as NotificationChannel and assign it to variable channel
        val channel = NotificationChannel(CHANNEL_ID, name, importance)

    //Hands over channel object over to Android operating system to register it in phone settings
        val manager = getSystemService(NotificationManager::class.java)

    // Android notification channel which allows for the system to route the alert
        manager.createNotificationChannel(channel)

    //  Constructs the actual visual notification alert
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher) //R.mimap.ic_launcher points to default app icon
            .setContentTitle("Life Loop Is Active")
            .setContentText("Monitoring user's data...")
            .build()
            // Bypasses Doze Mode(Doze mode kills standard background services to save battery life)
            startForeground(1, notification)
        return START_STICKY
    }
}