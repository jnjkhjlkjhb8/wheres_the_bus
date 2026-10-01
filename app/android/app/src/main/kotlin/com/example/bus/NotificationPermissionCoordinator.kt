package com.example.bus

class NotificationPermissionCoordinator(
    private val alreadyGranted: () -> Boolean,
    private val requiresRuntimePermission: () -> Boolean,
    private val launchRequest: () -> Unit,
) {
    private val pending = ArrayDeque<(Boolean) -> Unit>()

    /** True while a system permission request is in flight, awaiting [onPermissionResult]. */
    val hasPendingRequest: Boolean
        get() = !pending.isEmpty()

    fun request(onResult: (Boolean) -> Unit) {
        if (!requiresRuntimePermission() || alreadyGranted()) {
            onResult(true)
            return
        }
        val wasEmpty = pending.isEmpty()
        pending.addLast(onResult)
        if (wasEmpty) {
            launchRequest()
        }
    }

    /** Called from `onRequestPermissionsResult` with the user's decision. */
    fun onPermissionResult(granted: Boolean) {
        val callbacks = ArrayList<(Boolean) -> Unit>(pending)
        pending.clear()
        for (callback in callbacks) {
            callback(granted)
        }
    }
}
