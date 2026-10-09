package com.example.bus

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationPermissionCoordinatorTest {

    @Test
    fun `already granted resolves immediately without launching a request`() {
        var launched = false
        val coordinator = NotificationPermissionCoordinator(
            alreadyGranted = { true },
            requiresRuntimePermission = { true },
            launchRequest = { launched = true },
        )

        var result: Boolean? = null
        coordinator.request { result = it }

        assertEquals(true, result)
        assertFalse(launched)
        assertFalse(coordinator.hasPendingRequest)
    }

    @Test
    fun `pre-13 OS resolves immediately without launching a request`() {
        var launched = false
        val coordinator = NotificationPermissionCoordinator(
            alreadyGranted = { false },
            requiresRuntimePermission = { false },
            launchRequest = { launched = true },
        )

        var result: Boolean? = null
        coordinator.request { result = it }

        assertEquals(true, result)
        assertFalse(launched)
    }

    @Test
    fun `not yet granted launches a request and waits for the callback`() {
        var launchCount = 0
        val coordinator = NotificationPermissionCoordinator(
            alreadyGranted = { false },
            requiresRuntimePermission = { true },
            launchRequest = { launchCount++ },
        )

        var result: Boolean? = null
        coordinator.request { result = it }

        // Nothing resolved yet — start() must not complete before the
        // Activity Result callback fires.
        assertEquals(1, launchCount)
        assertEquals(null, result)
        assertTrue(coordinator.hasPendingRequest)

        coordinator.onPermissionResult(true)

        assertEquals(true, result)
        assertFalse(coordinator.hasPendingRequest)
    }

    @Test
    fun `denial callback resolves the pending request with false`() {
        val coordinator = NotificationPermissionCoordinator(
            alreadyGranted = { false },
            requiresRuntimePermission = { true },
            launchRequest = {},
        )

        var result: Boolean? = null
        coordinator.request { result = it }
        coordinator.onPermissionResult(false)

        assertEquals(false, result)
    }

    @Test
    fun `a second request while one is pending does not relaunch`() {
        var launchCount = 0
        val coordinator = NotificationPermissionCoordinator(
            alreadyGranted = { false },
            requiresRuntimePermission = { true },
            launchRequest = { launchCount++ },
        )

        var resultA: Boolean? = null
        var resultB: Boolean? = null
        coordinator.request { resultA = it }
        coordinator.request { resultB = it }

        assertEquals(1, launchCount)
        assertEquals(null, resultA)
        assertEquals(null, resultB)

        coordinator.onPermissionResult(true)

        assertEquals(true, resultA)
        assertEquals(true, resultB)
    }

    @Test
    fun `a request made after the previous one resolved launches again`() {
        var launchCount = 0
        val coordinator = NotificationPermissionCoordinator(
            alreadyGranted = { false },
            requiresRuntimePermission = { true },
            launchRequest = { launchCount++ },
        )

        coordinator.request {}
        coordinator.onPermissionResult(true)
        coordinator.request {}

        assertEquals(2, launchCount)
    }
}
