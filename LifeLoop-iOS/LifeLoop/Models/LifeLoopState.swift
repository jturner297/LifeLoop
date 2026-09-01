import Foundation

/// iOS equivalent of the Android `LifeLoopState` Kotlin data class.
struct LifeLoopState: Equatable {
    var bpm: Float = 0
    var state: Int = 0
    var latitude: Double = 0
    var longitude: Double = 0
}
