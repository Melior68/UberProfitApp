package com.uberprofit.auto

import android.accessibilityservice.AccessibilityService
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale
import kotlin.math.abs

class UberProfitAccessibilityService : AccessibilityService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val debounceIntervalSec = 25.0
    private val recentOfferHashes = mutableMapOf<Int, Double>()

    private var lastProcessedMillis: Long = 0L
    private var lastValidOfferSeenTimeSec: Double = 0.0
    private var didSendClearCard: Boolean = true
    private var didSendAcceptedForLastOffer: Boolean = true

    // Janela Flutuante Nativa (TYPE_ACCESSIBILITY_OVERLAY — não exige permissão extra SYSTEM_ALERT_WINDOW!)
    private var windowManager: WindowManager? = null
    private var rootContainer: LinearLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var headerBadgeView: TextView? = null
    private var kmMetricView: TextView? = null
    private var hourMetricView: TextView? = null
    private var footerDetailsView: TextView? = null
    private var acceptButtonView: TextView? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        activeInstance = this
        AppStateRepository.initIfNeeded(this)
        AppStateRepository.setAccessibilityConnected(true)
        val s = AppStateRepository.settings.value
        if (s.isShiftReadingEnabled && s.visualAlertMode != VisualAlertMode.NOTIFICATION) {
            showOrUpdateOverlayInternal()
        }
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        removeFloatingViewInternal()
        activeInstance = null
        AppStateRepository.setAccessibilityConnected(false)
        AppStateRepository.setOverlayActive(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        removeFloatingViewInternal()
        activeInstance = null
        AppStateRepository.setAccessibilityConnected(false)
        AppStateRepository.setOverlayActive(false)
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (!AppStateRepository.settings.value.isShiftReadingEnabled) return

        val pkgName = event.packageName?.toString()
        if (pkgName == packageName) return

        val nowSec = System.currentTimeMillis() / 1000.0

        // 1. Detecta clique no botão "Aceitar" enquanto uma oferta estava visível
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED) {
            val clickedText = buildString {
                event.text.forEach { append(it).append(" ") }
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

        // Throttle de 300ms
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

        if (RideScreenParser.isInsideOwnAppOrHistoryScreen(allScreenText, pkgName)) {
            return
        }

        val cleanCardLines = sortedLines.filterNot { RideScreenParser.isSelfOverlayLine(it.text) }
        val payload = RideScreenParser.parseRideCard(cleanCardLines, pkgName, nowSec)

        if (payload == null) {
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

    // MARK: - Janela Flutuante Nativa (TYPE_ACCESSIBILITY_OVERLAY)
    @SuppressLint("ClickableViewAccessibility")
    private fun showOrUpdateOverlayInternal() {
        mainHandler.post {
            if (rootContainer == null) {
                val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
                windowManager = wm

                val density = resources.displayMetrics.density
                fun dp(value: Int): Int = (value * density).toInt()

                val card = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(12), dp(10), dp(12), dp(10))
                    background = buildRoundedBackground(
                        Color.parseColor("#141923"),
                        Color.parseColor("#00BCD4"),
                        dp(18),
                        dp(2)
                    )
                }

                val topRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }

                val badge = TextView(this).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(4), dp(8), dp(4))
                    background = buildRoundedBackground(Color.parseColor("#45000000"), Color.TRANSPARENT, dp(8), 0)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                }
                headerBadgeView = badge

                val acceptBtn = TextView(this).apply {
                    text = "✅ Aceitei"
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(4), dp(8), dp(4))
                    background = buildRoundedBackground(Color.parseColor("#1B5E20"), Color.WHITE, dp(10), dp(1))
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                    lp.marginStart = dp(6)
                    layoutParams = lp
                    setOnClickListener {
                        AppStateRepository.acceptLatestRide(this@UberProfitAccessibilityService)
                        updateOverlayContentInternal()
                    }
                }
                acceptButtonView = acceptBtn

                val closeBtn = TextView(this).apply {
                    text = "✕"
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(3), dp(8), dp(3))
                    background = buildRoundedBackground(Color.parseColor("#55000000"), Color.TRANSPARENT, dp(10), 0)
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                    lp.marginStart = dp(6)
                    layoutParams = lp
                    setOnClickListener {
                        if (AppStateRepository.latestAnalysis.value != null) {
                            AppStateRepository.clearActiveCard(this@UberProfitAccessibilityService)
                        } else {
                            removeFloatingViewInternal()
                            AppStateRepository.setOverlayActive(false)
                        }
                    }
                }

                topRow.addView(badge)
                topRow.addView(acceptBtn)
                topRow.addView(closeBtn)

                val metricsRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(2), dp(6), dp(2), dp(4))
                }

                val kmTv = TextView(this).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 23f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                }
                kmMetricView = kmTv

                val hourTv = TextView(this).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 23f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    gravity = Gravity.END
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                }
                hourMetricView = hourTv

                metricsRow.addView(kmTv)
                metricsRow.addView(hourTv)

                val footerTv = TextView(this).apply {
                    setTextColor(Color.parseColor("#F5F5F5"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    gravity = Gravity.CENTER_HORIZONTAL
                }
                footerDetailsView = footerTv

                card.addView(topRow)
                card.addView(metricsRow)
                card.addView(footerTv)

                val params = WindowManager.LayoutParams(
                    dp(335),
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    x = 0
                    y = dp(78)
                }
                layoutParams = params

                var initialX = 0
                var initialY = 0
                var initialTouchX = 0f
                var initialTouchY = 0f

                card.setOnTouchListener { _, event ->
                    val lp = layoutParams ?: return@setOnTouchListener false
                    when (event.action) {
                        MotionEvent.ACTION_DOWN -> {
                            initialX = lp.x
                            initialY = lp.y
                            initialTouchX = event.rawX
                            initialTouchY = event.rawY
                            true
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val dx = (event.rawX - initialTouchX).toInt()
                            val dy = (event.rawY - initialTouchY).toInt()
                            if (abs(dx) > 4 || abs(dy) > 4) {
                                lp.x = initialX + dx
                                lp.y = initialY + dy
                                try {
                                    windowManager?.updateViewLayout(card, lp)
                                } catch (_: Exception) {
                                }
                            }
                            true
                        }
                        else -> false
                    }
                }

                try {
                    wm.addView(card, params)
                    rootContainer = card
                    AppStateRepository.setOverlayActive(true)
                } catch (_: Exception) {
                }
            }
            updateOverlayContentInternal()
        }
    }

    private fun updateOverlayContentInternal() {
        mainHandler.post {
            val card = rootContainer ?: return@post
            val density = resources.displayMetrics.density
            fun dp(value: Int): Int = (value * density).toInt()

            val analysis = AppStateRepository.latestAnalysis.value
            val settings = AppStateRepository.settings.value

            if (analysis == null) {
                card.background = buildRoundedBackground(
                    Color.parseColor("#141923"),
                    Color.parseColor("#00BCD4"),
                    dp(18),
                    dp(2)
                )
                headerBadgeView?.text = "UBER & 99 PROFIT ATIVO"
                acceptButtonView?.visibility = View.GONE
                kmMetricView?.text = "Monitorando..."
                kmMetricView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                hourMetricView?.text = "Meta R$ ${String.format(Locale("pt", "BR"), "%.2f", settings.targetBRLPerKm)}/km"
                hourMetricView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                footerDetailsView?.text = "Abra a Uber ou 99 • Arraste esta janela para onde preferir"
                return@post
            }

            val bgColor = when (analysis.verdict) {
                RideVerdict.APPROVED -> Color.parseColor("#0F8F3D")
                RideVerdict.WARNING -> Color.parseColor("#C78505")
                RideVerdict.REJECTED -> Color.parseColor("#B81924")
            }

            card.background = buildRoundedBackground(bgColor, Color.parseColor("#55FFFFFF"), dp(18), dp(2))

            val profitStr = String.format(Locale("pt", "BR"), "%.2f", analysis.netProfitBRL)
            headerBadgeView?.text = "${analysis.offer.appSource} • ${analysis.verdict.rawValue} • LUCRO R$ $profitStr"

            val alreadyAccepted = AppStateRepository.isRideAlreadyAccepted(analysis)
            acceptButtonView?.visibility = View.VISIBLE
            acceptButtonView?.text = if (alreadyAccepted) "✓ Salva" else "✅ Aceitei"

            val shownKm = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.NET) {
                analysis.netPerKm
            } else {
                analysis.grossPerKm
            }
            val shownHour = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.NET) {
                analysis.netPerHour
            } else {
                analysis.grossPerHour
            }

            kmMetricView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            hourMetricView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            kmMetricView?.text = String.format(Locale("pt", "BR"), "R$ %.2f/km", shownKm)
            hourMetricView?.text = String.format(Locale("pt", "BR"), "R$ %.0f/h", shownHour)

            footerDetailsView?.text = String.format(
                Locale("pt", "BR"),
                "Tarifa R$ %.2f • %.1f km total • %d min • Comb. -R$ %.2f",
                analysis.offer.fareBRL,
                analysis.offer.totalDistanceKm,
                analysis.offer.totalMinutes,
                analysis.fuelCostBRL
            )
        }
    }

    private fun removeFloatingViewInternal() {
        mainHandler.post {
            val view = rootContainer ?: return@post
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
            }
            rootContainer = null
        }
    }

    private fun buildRoundedBackground(
        fillColor: Int,
        strokeColor: Int,
        cornerRadiusPx: Int,
        strokeWidthPx: Int
    ): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = cornerRadiusPx.toFloat()
            setColor(fillColor)
            if (strokeWidthPx > 0) {
                setStroke(strokeWidthPx, strokeColor)
            }
        }
    }

    companion object {
        @Volatile
        private var activeInstance: UberProfitAccessibilityService? = null

        val isConnectedInstance: Boolean
            get() = activeInstance != null

        fun showOrUpdateOffer() {
            if (!AppStateRepository.settings.value.isShiftReadingEnabled) return
            activeInstance?.showOrUpdateOverlayInternal()
        }

        fun hideOverlayFromMasterSwitch() {
            val inst = activeInstance ?: return
            inst.removeFloatingViewInternal()
            AppStateRepository.setOverlayActive(false)
        }

        fun refreshIfRunning() {
            if (AppStateRepository.isOverlayActive.value) {
                activeInstance?.updateOverlayContentInternal()
            }
        }

        fun toggleOverlay(): Boolean {
            val inst = activeInstance ?: return false
            if (AppStateRepository.isOverlayActive.value) {
                inst.removeFloatingViewInternal()
                AppStateRepository.setOverlayActive(false)
            } else {
                inst.showOrUpdateOverlayInternal()
            }
            return true
        }
    }
}
