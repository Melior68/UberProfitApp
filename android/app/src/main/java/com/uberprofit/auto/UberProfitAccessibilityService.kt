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

    // Timer automático para recolher o card de volta para a Pílula Compacta após 8,5s sem oferta na tela
    private val autoClearRunnable = Runnable {
        val nowSec = System.currentTimeMillis() / 1000.0
        if (!didSendClearCard && (nowSec - lastValidOfferSeenTimeSec) >= 8.0) {
            didSendClearCard = true
            AppStateRepository.clearActiveCard(this@UberProfitAccessibilityService)
        }
    }

    // Janela Flutuante Nativa (TYPE_ACCESSIBILITY_OVERLAY — 100% imune a bloqueios do Play Protect)
    private var windowManager: WindowManager? = null
    private var rootContainer: LinearLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var headerBadgeView: TextView? = null
    private var acceptButtonView: TextView? = null
    private var pauseButtonView: TextView? = null
    private var metricsRowContainer: LinearLayout? = null
    private var kmMetricView: TextView? = null
    private var hourMetricView: TextView? = null
    private var footerDetailsView: TextView? = null

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
        mainHandler.removeCallbacks(autoClearRunnable)
        mainHandler.removeCallbacks(scanRunnable)
        mainHandler.removeCallbacks(heartbeatRunnable)
        heartbeatRunning = false
        removeFloatingViewInternal()
        activeInstance = null
        AppStateRepository.setAccessibilityConnected(false)
        AppStateRepository.setOverlayActive(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(autoClearRunnable)
        mainHandler.removeCallbacks(scanRunnable)
        mainHandler.removeCallbacks(heartbeatRunnable)
        heartbeatRunning = false
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
        if (RideScreenParser.isIgnoredPackage(pkgName)) return

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
                mainHandler.removeCallbacks(autoClearRunnable)
                AppStateRepository.onAutoDetectedRideAccepted(this)
                return
            }
        }

        if (RideScreenParser.isRideAppPackage(pkgName)) {
            lastRideAppEventMillis = System.currentTimeMillis()
            startHeartbeatIfNeeded()
        }

        // Trailing debounce: sempre agenda uma varredura ~250ms após o ÚLTIMO evento.
        // (Antes, o throttle descartava os eventos finais e o card da 99/Uber nunca era relido.)
        mainHandler.removeCallbacks(scanRunnable)
        val nowMillis = System.currentTimeMillis()
        if (nowMillis - lastProcessedMillis >= 600L) {
            performScan()
        } else {
            mainHandler.postDelayed(scanRunnable, 250L)
        }
    }

    private var lastRideAppEventMillis: Long = 0L
    private var heartbeatRunning = false

    private val scanRunnable = Runnable { performScan() }

    // Varredura periódica leve (a cada 1,2s) enquanto a Uber/99 está em uso,
    // para pegar ofertas mesmo quando o app não dispara eventos de acessibilidade.
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            val s = AppStateRepository.settings.value
            val idleMs = System.currentTimeMillis() - lastRideAppEventMillis
            if (!s.isShiftReadingEnabled || idleMs > 120_000L) {
                heartbeatRunning = false
                return
            }
            performScan()
            mainHandler.postDelayed(this, 1200L)
        }
    }

    private fun startHeartbeatIfNeeded() {
        if (heartbeatRunning) return
        heartbeatRunning = true
        mainHandler.postDelayed(heartbeatRunnable, 1200L)
    }

    private fun performScan() {
        if (!AppStateRepository.settings.value.isShiftReadingEnabled) return
        lastProcessedMillis = System.currentTimeMillis()
        val nowSec = lastProcessedMillis / 1000.0

        var detectedPayload: RideOfferPayload? = null
        var activeScreenText = ""
        val dump = StringBuilder()

        // Junta a janela ativa + todas as janelas interativas (cards da Uber/99 por cima do Waze/Maps)
        val roots = mutableListOf<AccessibilityNodeInfo>()
        try {
            rootInActiveWindow?.let { roots.add(it) }
        } catch (_: Exception) {
        }
        try {
            windows?.forEach { win ->
                val r = win.root
                if (r != null) roots.add(r)
            }
        } catch (_: Exception) {
        }

        val seenKeys = HashSet<String>()
        for (root in roots) {
            val rootPkg = root.packageName?.toString()
            if (rootPkg == packageName || RideScreenParser.isIgnoredPackage(rootPkg)) continue
            val key = "${rootPkg}_${root.windowId}"
            if (!seenKeys.add(key)) continue

            val res = inspectWindowNode(root, rootPkg, nowSec)
            if (RideScreenParser.isRideAppPackage(rootPkg) && res.second.isNotEmpty()) {
                dump.append("📦 ").append(rootPkg).append("\n").append(res.second).append("\n\n")
            }
            if (res.second.isNotEmpty() && activeScreenText.isEmpty()) {
                activeScreenText = res.second
            }
            if (res.first != null) {
                detectedPayload = res.first
                activeScreenText = res.second
                break
            }
        }

        if (dump.isNotEmpty()) {
            val header = if (detectedPayload != null) {
                String.format(
                    java.util.Locale("pt", "BR"),
                    "✅ OFERTA RECONHECIDA: R$ %.2f • %.1f km • %d min\n\n",
                    detectedPayload.fareBRL, detectedPayload.totalDistanceKm, detectedPayload.totalMinutes
                )
            } else {
                "⚠️ Nenhuma oferta reconhecida nesta leitura\n\n"
            }
            AppStateRepository.setLastScreenDump(header + dump.toString().take(4000))
        }

        if (detectedPayload == null) {
            if (!didSendAcceptedForLastOffer &&
                lastValidOfferSeenTimeSec > 0 &&
                (nowSec - lastValidOfferSeenTimeSec) <= 22.0 &&
                activeScreenText.isNotEmpty() &&
                RideScreenParser.isAcceptedTripScreen(activeScreenText)
            ) {
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                mainHandler.removeCallbacks(autoClearRunnable)
                AppStateRepository.onAutoDetectedRideAccepted(this)
                return
            }
            checkAndClearStaleCard(nowSec)
            return
        }

        // Oferta válida encontrada na tela!
        lastValidOfferSeenTimeSec = nowSec
        didSendClearCard = false
        didSendAcceptedForLastOffer = false

        // Agenda limpeza automática para 8,5s caso o card suma e o mapa fique parado
        mainHandler.removeCallbacks(autoClearRunnable)
        mainHandler.postDelayed(autoClearRunnable, 8500L)

        val offerHash = ProfitCalculator.computeOfferHash(
            fare = detectedPayload.fareBRL,
            totalKm = detectedPayload.totalDistanceKm,
            totalMin = detectedPayload.totalMinutes
        )
        pruneExpiredHashes(nowSec)

        val lastSeen = recentOfferHashes[offerHash]
        if (lastSeen != null && (nowSec - lastSeen) < debounceIntervalSec) {
            return
        }

        recentOfferHashes[offerHash] = nowSec
        AppStateRepository.processIncomingOffer(this, detectedPayload)
    }

    private fun inspectWindowNode(
        rootNode: AccessibilityNodeInfo,
        pkgName: String?,
        nowSec: Double
    ): Pair<RideOfferPayload?, String> {
        val collectedLines = mutableListOf<ScreenTextLine>()
        collectTextLines(rootNode, collectedLines, requireVisible = true, depth = 0)
        // Alguns apps (ex: 99) marcam os textos do card como "não visíveis" para a acessibilidade.
        // Se não achamos nenhum "R$", refazemos a coleta sem o filtro de visibilidade.
        if (RideScreenParser.isRideAppPackage(pkgName) && collectedLines.none { it.text.contains("R$") }) {
            collectedLines.clear()
            collectTextLines(rootNode, collectedLines, requireVisible = false, depth = 0)
        }
        if (collectedLines.isEmpty()) return Pair(null, "")

        val sortedLines = collectedLines.sortedWith(compareBy<ScreenTextLine> { it.topY }.thenBy { it.leftX })
        val allScreenText = sortedLines.joinToString("\n") { it.text }

        if (RideScreenParser.isInsideOwnAppOrHistoryScreen(allScreenText, pkgName)) {
            return Pair(null, "")
        }

        val cleanCardLines = sortedLines.filterNot { RideScreenParser.isSelfOverlayLine(it.text) }
        val payload = RideScreenParser.parseRideCard(cleanCardLines, pkgName, nowSec)
        return Pair(payload, allScreenText)
    }

    private fun collectTextLines(
        node: AccessibilityNodeInfo?,
        output: MutableList<ScreenTextLine>,
        requireVisible: Boolean,
        depth: Int
    ) {
        if (node == null || depth > 60 || output.size > 600) return
        if (requireVisible && !node.isVisibleToUser) return

        val rect = Rect()
        node.getBoundsInScreen(rect)
        // Ignora nós fora da tela (bounds vazios) quando estamos sem filtro de visibilidade
        if (!requireVisible && (rect.width() <= 0 || rect.height() <= 0)) return

        val rawText = node.text?.toString()?.let { normalizeText(it) }
        val rawDesc = node.contentDescription?.toString()?.let { normalizeText(it) }

        // Lê o texto E a descrição (algumas versões da 99/Uber colocam o valor só na descrição)
        if (!rawText.isNullOrEmpty()) {
            output.add(ScreenTextLine(text = rawText, topY = rect.top, height = rect.height().coerceAtLeast(12), leftX = rect.left))
        }
        if (!rawDesc.isNullOrEmpty() && rawDesc != rawText) {
            output.add(ScreenTextLine(text = rawDesc, topY = rect.top, height = rect.height().coerceAtLeast(12), leftX = rect.left))
        }

        val childCount = node.childCount
        for (i in 0 until childCount) {
            val child = try {
                node.getChild(i)
            } catch (_: Exception) {
                null
            }
            if (child != null) {
                collectTextLines(child, output, requireVisible, depth + 1)
            }
        }
    }

    private fun normalizeText(raw: String): String {
        return raw
            .replace('\u00A0', ' ')
            .replace('\u202F', ' ')
            .replace('\u2009', ' ')
            .trim()
    }

    private fun checkAndClearStaleCard(nowSec: Double) {
        if (!didSendClearCard && (nowSec - lastValidOfferSeenTimeSec) >= 7.0) {
            didSendClearCard = true
            mainHandler.removeCallbacks(autoClearRunnable)
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

    // MARK: - Janela Flutuante Inteligente (Pílula Compacta em Espera ↔ Card Expandido na Corrida)
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
                    setPadding(dp(12), dp(8), dp(12), dp(8))
                    background = buildRoundedBackground(
                        Color.parseColor("#E6111827"),
                        Color.parseColor("#10B981"),
                        dp(22),
                        dp(2)
                    )
                }

                val topRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }

                val badge = TextView(this).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(4), dp(8), dp(4))
                    background = buildRoundedBackground(Color.parseColor("#38000000"), Color.TRANSPARENT, dp(10), 0)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                }
                headerBadgeView = badge

                val acceptBtn = TextView(this).apply {
                    text = "✅ Aceitei"
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(9), dp(4), dp(9), dp(4))
                    background = buildRoundedBackground(Color.parseColor("#065F46"), Color.WHITE, dp(10), dp(1))
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

                // Botão rápido de Pausar Turno direto na Pílula Flutuante
                val pauseBtn = TextView(this).apply {
                    text = "⏸"
                    setTextColor(Color.parseColor("#FBBF24"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(3), dp(8), dp(3))
                    background = buildRoundedBackground(Color.parseColor("#55000000"), Color.parseColor("#44FBBF24"), dp(10), dp(1))
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                    lp.marginStart = dp(6)
                    layoutParams = lp
                    setOnClickListener {
                        AppStateRepository.toggleShiftReading(this@UberProfitAccessibilityService)
                    }
                }
                pauseButtonView = pauseBtn

                val closeBtn = TextView(this).apply {
                    text = "✕"
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    setPadding(dp(8), dp(3), dp(8), dp(3))
                    background = buildRoundedBackground(Color.parseColor("#55000000"), Color.TRANSPARENT, dp(10), 0)
                    val lp = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    )
                    lp.marginStart = dp(5)
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
                topRow.addView(pauseBtn)
                topRow.addView(closeBtn)

                val metricsRow = LinearLayout(this).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(2), dp(6), dp(2), dp(4))
                }
                metricsRowContainer = metricsRow

                val kmTv = TextView(this).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                }
                kmMetricView = kmTv

                val hourTv = TextView(this).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
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
                    setTextColor(Color.parseColor("#F9FAFB"))
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                    typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    gravity = Gravity.CENTER_HORIZONTAL
                }
                footerDetailsView = footerTv

                card.addView(topRow)
                card.addView(metricsRow)
                card.addView(footerTv)

                val params = WindowManager.LayoutParams(
                    dp(285),
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    x = 0
                    y = dp(72)
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
            val lp = layoutParams ?: return@post
            val density = resources.displayMetrics.density
            fun dp(value: Int): Int = (value * density).toInt()

            val analysis = AppStateRepository.latestAnalysis.value
            val settings = AppStateRepository.settings.value

            // MODO 1: PÍLULA COMPACTA DISCRETA (Quando não há oferta tocando na tela)
            if (analysis == null) {
                card.setPadding(dp(10), dp(6), dp(10), dp(6))
                card.background = buildRoundedBackground(
                    Color.parseColor("#E6111827"),
                    Color.parseColor("#10B981"),
                    dp(24),
                    dp(2)
                )
                val targetStr = String.format(Locale("pt", "BR"), "%.2f", settings.targetBRLPerKm)
                headerBadgeView?.text = "🟢 Profit Ativo • Meta R$ $targetStr/km"
                acceptButtonView?.visibility = View.GONE
                pauseButtonView?.visibility = View.VISIBLE
                metricsRowContainer?.visibility = View.GONE
                footerDetailsView?.visibility = View.GONE

                val targetWidth = dp(285)
                if (lp.width != targetWidth) {
                    lp.width = targetWidth
                    try {
                        windowManager?.updateViewLayout(card, lp)
                    } catch (_: Exception) {
                    }
                }
                return@post
            }

            // MODO 2: CARD EXPANDIDO EM CORES VIVAS (Quando uma corrida toca na Uber ou 99!)
            val bgColor = when (analysis.verdict) {
                RideVerdict.APPROVED -> Color.parseColor("#059669")
                RideVerdict.WARNING -> Color.parseColor("#D97706")
                RideVerdict.REJECTED -> Color.parseColor("#DC2626")
            }

            card.setPadding(dp(12), dp(10), dp(12), dp(10))
            card.background = buildRoundedBackground(bgColor, Color.parseColor("#80FFFFFF"), dp(18), dp(2))

            val profitStr = String.format(Locale("pt", "BR"), "%.2f", analysis.netProfitBRL)
            headerBadgeView?.text = "${analysis.offer.appSource} • ${analysis.verdict.rawValue} • LUCRO R$ $profitStr"

            val alreadyAccepted = AppStateRepository.isRideAlreadyAccepted(analysis)
            acceptButtonView?.visibility = View.VISIBLE
            acceptButtonView?.text = if (alreadyAccepted) "✓ Salva" else "✅ Aceitei"
            pauseButtonView?.visibility = View.GONE
            metricsRowContainer?.visibility = View.VISIBLE
            footerDetailsView?.visibility = View.VISIBLE

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

            val distDetail = if (analysis.offer.pickupDistanceKm > 0.05 && analysis.offer.tripDistanceKm > 0.05) {
                String.format(
                    Locale("pt", "BR"),
                    "Busca %.1f + Viagem %.1f km",
                    analysis.offer.pickupDistanceKm,
                    analysis.offer.tripDistanceKm
                )
            } else {
                String.format(Locale("pt", "BR"), "%.1f km total", analysis.offer.totalDistanceKm)
            }

            footerDetailsView?.text = String.format(
                Locale("pt", "BR"),
                "Tarifa R$ %.2f • %s (%d min) • Comb. -R$ %.2f",
                analysis.offer.fareBRL,
                distDetail,
                analysis.offer.totalMinutes,
                analysis.fuelCostBRL
            )

            val expandedWidth = dp(342)
            if (lp.width != expandedWidth) {
                lp.width = expandedWidth
                try {
                    windowManager?.updateViewLayout(card, lp)
                } catch (_: Exception) {
                }
            }
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
