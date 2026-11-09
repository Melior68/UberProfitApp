package com.uberprofit.auto

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class UberProfitAccessibilityService : AccessibilityService() {

    private val debounceIntervalSec = 25.0
    private val recentOfferHashes = mutableMapOf<Int, Double>()

    private var lastProcessedMillis: Long = 0L
    private var lastValidOfferSeenTimeSec: Double = 0.0
    private var didSendClearCard: Boolean = true
    private var didSendAcceptedForLastOffer: Boolean = true

    override fun onServiceConnected() {
        super.onServiceConnected()
        isConnectedInstance = true
        AppStateRepository.initIfNeeded(this)
        AppStateRepository.setAccessibilityConnected(true)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        isConnectedInstance = false
        AppStateRepository.setAccessibilityConnected(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        isConnectedInstance = false
        AppStateRepository.setAccessibilityConnected(false)
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return

        val pkgName = event.packageName?.toString()
        if (pkgName == packageName) return

        val nowSec = System.currentTimeMillis() / 1000.0

        // 1. Se o motorista clicou diretamente no botão "Aceitar" enquanto uma oferta estava ativa:
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED) {
            val clickedText = buildString {
                event.text?.forEach { append(it).append(" ") }
                event.contentDescription?.let { append(it) }
            }.uppercase()

            if (!didSendAcceptedForLastOffer &&
                lastValidOfferSeenTimeSec > 0 &&
                (nowSec - lastValidOfferSeenTimeSec) <= 25.0 &&
                (clickedText.contains("ACEITAR") || clickedText.contains("TOQUE PARA ACEITAR"))
            ) {
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                AppStateRepository.onAutoDetectedRideAccepted(this)
                return
            }
        }

        // Throttle de 300ms para leitura super leve e sem gastar bateria
        val nowMillis = System.currentTimeMillis()
        if (nowMillis - lastProcessedMillis < 300L) return
        lastProcessedMillis = nowMillis

        val rootNode = rootInActiveWindow ?: return
        val collectedLines = mutableListOf<ScreenTextLine>()
        collectTextLines(rootNode, collectedLines)

        if (collectedLines.isEmpty()) {
            checkAndClearStaleCard(nowSec)
            return
        }

        val sortedLines = collectedLines.sortedBy { it.topY }
        val allScreenText = sortedLines.joinToString("\n") { it.text }

        // Bloqueia leitura se estiver no próprio app ou em telas de Histórico / Extrato da Uber ou 99
        if (RideScreenParser.isInsideOwnAppOrHistoryScreen(allScreenText, pkgName)) {
            return
        }

        val cleanCardLines = sortedLines.filterNot { RideScreenParser.isSelfOverlayLine(it.text) }
        val payload = RideScreenParser.parseRideCard(cleanCardLines, pkgName, nowSec)

        if (payload == null) {
            // Verifica se a tela mudou para "Iniciar viagem / A caminho do embarque" logo após uma oferta
            if (!didSendAcceptedForLastOffer &&
                lastValidOfferSeenTimeSec > 0 &&
                (nowSec - lastValidOfferSeenTimeSec) <= 22.0 &&
                RideScreenParser.isAcceptedTripScreen(allScreenText)
            ) {
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                AppStateRepository.onAutoDetectedRideAccepted(this)
                return
            }
            checkAndClearStaleCard(nowSec)
            return
        }

        lastValidOfferSeenTimeSec = nowSec
        didSendClearCard = false
        didSendAcceptedForLastOffer = false

        val offerHash = ProfitCalculator.computeOfferHash(
            fare = payload.fareBRL,
            totalKm = payload.totalDistanceKm,
            totalMin = payload.totalMinutes
        )
        pruneExpiredHashes(nowSec)

        val lastSeen = recentOfferHashes[offerHash]
        if (lastSeen != null && (nowSec - lastSeen) < debounceIntervalSec) {
            return
        }

        recentOfferHashes[offerHash] = nowSec
        AppStateRepository.processIncomingOffer(this, payload)
    }

    private fun collectTextLines(
        node: AccessibilityNodeInfo?,
        output: MutableList<ScreenTextLine>
    ) {
        if (node == null || !node.isVisibleToUser) return

        val rawText = node.text?.toString()?.trim()
        val rawDesc = node.contentDescription?.toString()?.trim()
        val chosen = when {
            !rawText.isNullOrEmpty() -> rawText
            !rawDesc.isNullOrEmpty() -> rawDesc
            else -> null
        }

        if (!chosen.isNullOrEmpty()) {
            val clean = chosen.replace('\u00A0', ' ').trim()
            if (clean.isNotEmpty()) {
                val rect = Rect()
                node.getBoundsInScreen(rect)
                output.add(
                    ScreenTextLine(
                        text = clean,
                        topY = rect.top,
                        height = rect.height().coerceAtLeast(12)
                    )
                )
            }
        }

        val childCount = node.childCount
        for (i in 0 until childCount) {
            val child = try {
                node.getChild(i)
            } catch (_: Exception) {
                null
            }
            if (child != null) {
                collectTextLines(child, output)
            }
        }
    }

    private fun checkAndClearStaleCard(nowSec: Double) {
        if (!didSendClearCard && (nowSec - lastValidOfferSeenTimeSec) >= 7.0) {
            didSendClearCard = true
            AppStateRepository.clearActiveCard(this)
        }
    }

    private fun pruneExpiredHashes(nowSec: Double) {
        val iterator = recentOfferHashes.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if ((nowSec - entry.value) >= debounceIntervalSec) {
                iterator.remove()
            }
        }
    }

    companion object {
        @Volatile
        var isConnectedInstance: Boolean = false
    }
}
