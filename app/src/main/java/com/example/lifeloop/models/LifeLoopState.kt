package com.example.lifeloop.models
// Data model: Kotlin data class that structures the incoming telemetry(noted below)

data class LifeLoopState(
    val bpm: Float = 0f,
    val state: Int = 0,
    val latitude: Double = 0.0,
    val longitude: Double = 0.0
)