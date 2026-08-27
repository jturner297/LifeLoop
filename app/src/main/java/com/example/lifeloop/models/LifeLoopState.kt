package com.example.lifeloop.models


data class LifeLoopState(
    val bpm: Float = 0f,
    val state: Int = 0,
    val latitude: Double = 0.0,
    val longitude: Double = 0.0
)