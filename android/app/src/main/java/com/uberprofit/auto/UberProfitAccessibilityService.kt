package com.uberprofit.auto

import android.accessibilityservice.AccessibilityService
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
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

    // Timer automático para recolher o card de volta para a Pílula Compacta após 5s sem oferta na tela
    private val autoClearRunnable = Runnable {
        val nowSec = System.currentTimeMillis() / 1000.0
        if (!didSendClearCard && (nowSec - lastValidOfferSeenTimeSec) >= 5.0) {
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
            startHeartbeatIfNeeded()
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

        startHeartbeatIfNeeded()

        val pkgName = event.packageName?.toString() ?: ""
        if (pkgName == packageName) return

        // Se uma janela de captura de print (SmartCapture) acabou de abrir, marca timestamp para evitar ler card cortado
        val pkgLower = pkgName.lowercase()
        if (pkgLower.contains("smartcapture") || pkgLower.contains("screenshot") || pkgLower.contains("markup")) {
            lastScreenshotOverlayMillis = System.currentTimeMillis()
            return
        }

        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            // Ignora eventos de janela da SystemUI (barra de status/volume/notificação) ao rastrear o app principal
            if (pkgName.isNotEmpty() && !pkgLower.contains("systemui") && !pkgLower.contains("inputmethod") && !pkgLower.contains("keyboard")) {
                lastApplicationPackage = pkgName
            }
        }

        if (RideScreenParser.isIgnoredPackage(pkgName)) return

        val nowSec = System.currentTimeMillis() / 1000.0

        // 1. Detecta clique no botão "Aceitar" / "Escolher" enquanto uma oferta estava visível
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_CLICKED && RideScreenParser.isRideAppPackage(pkgName)) {
            val clickedText = buildString {
                event.text.forEach { append(it).append(" ") }
                event.contentDescription?.let { append(it) }
            }.uppercase()

            if (!didSendAcceptedForLastOffer &&
                lastValidOfferSeenTimeSec > 0 &&
                (nowSec - lastValidOfferSeenTimeSec) <= 25.0 &&
                (clickedText.contains("ACEITAR") || clickedText.contains("TOQUE PARA ACEITAR") || clickedText.contains("ESCOLHER"))
            ) {
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                mainHandler.removeCallbacks(autoClearRunnable)
                AppStateRepository.onAutoDetectedRideAccepted(this)
                return
            }
        }

        // 2. Captura nós anexados diretamente ao evento da 99/Uber
        if (RideScreenParser.isRideAppPackage(pkgName)) {
            lastRideAppEventMillis = System.currentTimeMillis()
            lastApplicationPackage = pkgName
            try {
                event.source?.let { src ->
                    cacheEventSourceNode(src, pkgName)
                }
            } catch (_: Exception) {
            }
        } else {
            // Se o evento não veio da 99/Uber e a 99/Uber não está visível na tela, ignora sem esconder a pílula!
            val ctx = detectVisibleRideAppWindow()
            if (!ctx.isRideAppVisible) return
        }

        // Trailing debounce: agenda varredura após o evento
        mainHandler.removeCallbacks(scanRunnable)
        val nowMillis = System.currentTimeMillis()
        if (nowMillis - lastProcessedMillis >= 480L) {
            performScan()
        } else {
            mainHandler.postDelayed(scanRunnable, 200L)
        }
    }

    private var lastRideAppEventMillis: Long = 0L
    private var lastScreenshotOverlayMillis: Long = 0L
    private var lastApplicationPackage: String = ""
    private var heartbeatRunning = false
    private val cachedEventLines = mutableListOf<ScreenTextLine>()
    private var lastCachedEventMillis: Long = 0L

    private data class RideWindowContext(
        val isRideAppVisible: Boolean,
        val ridePackageName: String?,
        val rideWindowBounds: Rect?,
        val hasObstructingOverlay: Boolean
    )

    /**
     * Verifica diretamente nas janelas do Android se a interface da 99 ou da Uber está na tela,
     * sem nunca esconder a pílula flutuante e ignorando outros apps.
     */
    private fun detectVisibleRideAppWindow(): RideWindowContext {
        var foundRidePkg: String? = null
        var foundRideBounds: Rect? = null
        var hasObstruction = (System.currentTimeMillis() - lastScreenshotOverlayMillis) < 2200L

        try {
            val activeRoot = rootInActiveWindow
            val activePkg = activeRoot?.packageName?.toString()
            if (activePkg == packageName) {
                // O próprio app UberProfit está aberto na tela
                return RideWindowContext(false, null, null, false)
            }
            if (RideScreenParser.isRideAppPackage(activePkg)) {
                foundRidePkg = activePkg
                val b = Rect()
                try { activeRoot?.getBoundsInScreen(b) } catch (_: Exception) {}
                if (!b.isEmpty) foundRideBounds = b
            }
        } catch (_: Exception) {
        }

        var windowsAvailable = false
        try {
            val winList = windows
            if (!winList.isNullOrEmpty()) {
                windowsAvailable = true
                for (win in winList) {
                    val r = try { win.root } catch (_: Exception) { null } ?: continue
                    val pkg = r.packageName?.toString() ?: continue
                    val pkgLow = pkg.lowercase()

                    if (pkgLow.contains("smartcapture") || pkgLow.contains("screenshot") || pkgLow.contains("markup")) {
                        hasObstruction = true
                    }

                    if (win.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION) {
                        if (pkg == packageName) {
                            return RideWindowContext(false, null, null, false)
                        }
                        if (RideScreenParser.isRideAppPackage(pkg)) {
                            foundRidePkg = pkg
                            val b = Rect()
                            try { win.getBoundsInScreen(b) } catch (_: Exception) {}
                            if (!b.isEmpty) foundRideBounds = b
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }

        // Fallback caso a lista de janelas esteja em transição mas o app ativo seja 99/Uber
        if (foundRidePkg == null && !windowsAvailable && RideScreenParser.isRideAppPackage(lastApplicationPackage)) {
            foundRidePkg = lastApplicationPackage
        }

        return RideWindowContext(
            isRideAppVisible = foundRidePkg != null,
            ridePackageName = foundRidePkg,
            rideWindowBounds = foundRideBounds,
            hasObstructingOverlay = hasObstruction
        )
    }

    /**
     * Retorna a posição exata da nossa Pílula/Card Flutuante na tela (onde quer que o motorista a tenha arrastado),
     * garantindo que o OCR e o leitor NUNCA leiam os próprios números do nosso card.
     */
    private fun getOverlayBoundsOnScreen(): Rect? {
        val view = rootContainer ?: return null
        if (!view.isShown || view.width <= 0 || view.height <= 0) return null
        val loc = IntArray(2)
        return try {
            view.getLocationOnScreen(loc)
            Rect(
                loc[0] - 24,
                loc[1] - 24,
                loc[0] + view.width + 24,
                loc[1] + view.height + 24
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun cacheEventSourceNode(sourceNode: AccessibilityNodeInfo, pkgName: String?) {
        if (!RideScreenParser.isRideAppPackage(pkgName)) return
        val now = System.currentTimeMillis()
        if (now - lastCachedEventMillis > 3500L) {
            cachedEventLines.clear()
        }
        val overlayRect = getOverlayBoundsOnScreen()
        var topNode: AccessibilityNodeInfo = sourceNode
        var hops = 0
        while (hops < 15) {
            val parent = try { topNode.parent } catch (_: Exception) { null } ?: break
            topNode = parent
            hops++
        }
        val lines = mutableListOf<ScreenTextLine>()
        collectTextLines(topNode, lines, requireVisible = false, depth = 0, overlayRect = overlayRect)
        if (lines.any { it.text.contains("R$") || it.text.contains("km", ignoreCase = true) || it.text.contains("min", ignoreCase = true) }) {
            cachedEventLines.clear()
            cachedEventLines.addAll(lines)
            lastCachedEventMillis = now
        }
    }

    private val scanRunnable = Runnable { performScan() }

    // Varredura periódica contínua (a cada 1,2s) enquanto o leitor estiver LIGADO.
    // Nunca desliga sozinha após 2 min de espera — assim que tocar corrida na 99 ou Uber, ela detecta na hora!
    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            val s = AppStateRepository.settings.value
            if (!s.isShiftReadingEnabled) {
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
        mainHandler.postDelayed(heartbeatRunnable, 1000L)
    }

    private var isOcrProcessing = false
    private var lastOcrMillis = 0L

    /**
     * OCR Visual Direto via Google ML Kit: Captura a tela e extrai os textos visíveis SOMENTE da janela da 99/Uber,
     * excluindo a área da nossa pílula flutuante (em qualquer posição da tela) e barras de print.
     */
    private fun tryVisualOcrScan(nowSec: Double, rideCtx: RideWindowContext) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        if (!rideCtx.isRideAppVisible || rideCtx.hasObstructingOverlay) return
        if (isOcrProcessing) return
        val now = System.currentTimeMillis()
        if (now - lastOcrMillis < 1150L) return

        isOcrProcessing = true
        lastOcrMillis = now
        val overlayRectSnapshot = getOverlayBoundsOnScreen()
        val rideBoundsSnapshot = rideCtx.rideWindowBounds
        val targetPkg = rideCtx.ridePackageName ?: "com.app99.driver"

        try {
            takeScreenshot(
                android.view.Display.DEFAULT_DISPLAY,
                mainExecutor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(screenshot: ScreenshotResult) {
                        val hardwareBuffer = screenshot.hardwareBuffer
                        val colorSpace = screenshot.colorSpace
                        var bitmap: android.graphics.Bitmap? = null
                        try {
                            val rawBitmap = android.graphics.Bitmap.wrapHardwareBuffer(hardwareBuffer, colorSpace)
                            bitmap = rawBitmap?.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
                        } catch (_: Exception) {
                        } finally {
                            try { hardwareBuffer.close() } catch (_: Exception) {}
                        }

                        if (bitmap == null) {
                            isOcrProcessing = false
                            return
                        }

                        val currentOverlayRect = getOverlayBoundsOnScreen() ?: overlayRectSnapshot
                        val inputImage = com.google.mlkit.vision.common.InputImage.fromBitmap(bitmap, 0)
                        val recognizer = com.google.mlkit.vision.text.TextRecognition.getClient(
                            com.google.mlkit.vision.text.latin.TextRecognizerOptions.DEFAULT_OPTIONS
                        )

                        recognizer.process(inputImage)
                            .addOnSuccessListener { visionText ->
                                val ocrLines = mutableListOf<ScreenTextLine>()
                                for (block in visionText.textBlocks) {
                                    for (line in block.lines) {
                                        val box = line.boundingBox
                                        val top = box?.top ?: 0
                                        val left = box?.left ?: 0
                                        val height = box?.height() ?: 24
                                        val norm = normalizeText(line.text)
                                        if (norm.isEmpty()) continue

                                        // 1. Exclui barra de status do topo
                                        if (top <= 110) continue

                                        // 2. Exclui qualquer texto dentro da área atual da nossa Pílula/Card Flutuante
                                        if (box != null && currentOverlayRect != null && Rect.intersects(box, currentOverlayRect)) {
                                            continue
                                        }

                                        // 3. Se soubermos os limites da janela da 99/Uber, lê apenas dentro dela
                                        if (box != null && rideBoundsSnapshot != null && !rideBoundsSnapshot.isEmpty) {
                                            if (!rideBoundsSnapshot.contains(box.centerX(), box.centerY())) {
                                                continue
                                            }
                                        }

                                        ocrLines.add(ScreenTextLine(text = norm, topY = top, leftX = left, height = height))
                                    }
                                }

                                if (ocrLines.isNotEmpty()) {
                                    val filteredOcr = ocrLines.filter { item ->
                                        val isNotSelfOverlay = !RideScreenParser.isSelfOverlayLine(item.text)
                                        val isNotScreenshotMenu = !item.text.contains("Captura") &&
                                            !item.text.contains("Compartilhar") &&
                                            !item.text.contains("Editar") &&
                                            !item.text.contains("Salvar")
                                        isNotSelfOverlay && isNotScreenshotMenu
                                    }

                                    val sortedOcr = filteredOcr.sortedWith(compareBy<ScreenTextLine> { it.topY }.thenBy { it.leftX })
                                    val fullOcrText = sortedOcr.joinToString("\n") { it.text }

                                    if (!RideScreenParser.isInsideOwnAppOrHistoryScreen(fullOcrText, targetPkg)) {
                                        val payload = RideScreenParser.parseRideCard(sortedOcr, targetPkg, nowSec)

                                        if (payload != null) {
                                            val ocrDump = "👁️ [OCR VISUAL ML KIT - OFERTA DETECTADA]\n$fullOcrText"
                                            AppStateRepository.setLastScreenDump(ocrDump, isRichOrOffer = true)
                                            handleRecognizedOffer(payload, nowSec)
                                        } else if (fullOcrText.contains("R$") || fullOcrText.contains("/km") || fullOcrText.contains("min (")) {
                                            val ocrDump = "👁️ [OCR VISUAL ML KIT - LIDO DA TELA]\n$fullOcrText"
                                            AppStateRepository.setLastScreenDump(ocrDump, isRichOrOffer = true)
                                        }
                                    }
                                }
                                isOcrProcessing = false
                            }
                            .addOnFailureListener {
                                isOcrProcessing = false
                            }
                    }

                    override fun onFailure(errorCode: Int) {
                        isOcrProcessing = false
                    }
                }
            )
        } catch (_: Exception) {
            isOcrProcessing = false
        }
    }

    private fun performScan() {
        if (!AppStateRepository.settings.value.isShiftReadingEnabled) return
        lastProcessedMillis = System.currentTimeMillis()
        val nowSec = lastProcessedMillis / 1000.0

        val rideCtx = detectVisibleRideAppWindow()
        if (!rideCtx.isRideAppVisible || rideCtx.hasObstructingOverlay) {
            // Se não estiver na tela da 99/Uber, mantém a pílula visível, mas não lê outros apps!
            checkAndClearStaleCard(nowSec)
            return
        }

        val overlayRect = getOverlayBoundsOnScreen()
        var detectedPayload: RideOfferPayload? = null
        var activeScreenText = ""
        val dump = StringBuilder()

        // Coleta SOMENTE janelas da Uber e da 99
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
        for ((idx, root) in roots.withIndex()) {
            try { root.refresh() } catch (_: Exception) {}
            val rootPkg = root.packageName?.toString()
            // REGRA DE OURO: Lê EXCLUSIVAMENTE pacotes da Uber ou 99! Ignora qualquer outro app/sobreposição.
            if (!RideScreenParser.isRideAppPackage(rootPkg)) continue

            val rootBounds = Rect()
            try { root.getBoundsInScreen(rootBounds) } catch (_: Exception) {}
            val key = "${rootPkg}_${root.windowId}_${root.className}_${rootBounds.top}_${rootBounds.bottom}_$idx"
            if (!seenKeys.add(key)) continue

            val res = inspectWindowNode(root, rootPkg, nowSec, overlayRect)
            if (res.second.isNotEmpty()) {
                dump.append("📦 ").append(rootPkg).append(" (win=").append(root.windowId).append(")\n").append(res.second).append("\n\n")
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

        // Se as janelas raízes (ex: Dialog "Erro de rede") cobriram o card, analisa os nós capturados direto do evento da 99/Uber!
        if (detectedPayload == null &&
            cachedEventLines.isNotEmpty() &&
            (lastProcessedMillis - lastCachedEventMillis) <= 3500L
        ) {
            val sortedCached = cachedEventLines.sortedWith(compareBy<ScreenTextLine> { it.topY }.thenBy { it.leftX })
            val cachedText = sortedCached.joinToString("\n") { it.text }
            val cleanCached = sortedCached.filterNot { RideScreenParser.isSelfOverlayLine(it.text) }
            val cachedPayload = RideScreenParser.parseRideCard(cleanCached, rideCtx.ridePackageName ?: "com.app99.driver", nowSec)
            if (cachedText.isNotEmpty()) {
                dump.append("📦 event.source (cache recente)\n").append(cachedText).append("\n\n")
            }
            if (cachedPayload != null) {
                detectedPayload = cachedPayload
                activeScreenText = cachedText
            }
        }

        if (dump.isNotEmpty()) {
            val rawDumpStr = dump.toString()
            val hasRichOfferContent = detectedPayload != null ||
                rawDumpStr.contains("R$") ||
                rawDumpStr.contains("/km", ignoreCase = true) ||
                rawDumpStr.contains("min (", ignoreCase = true)
            val header = if (detectedPayload != null) {
                String.format(
                    java.util.Locale("pt", "BR"),
                    "✅ OFERTA RECONHECIDA: R$ %.2f • %.1f km • %d min\n\n",
                    detectedPayload.fareBRL, detectedPayload.totalDistanceKm, detectedPayload.totalMinutes
                )
            } else {
                "⚠️ Nenhuma oferta reconhecida nesta leitura\n\n"
            }
            AppStateRepository.setLastScreenDump(
                dump = header + rawDumpStr.take(3500),
                isRichOrOffer = hasRichOfferContent
            )
        }

        if (detectedPayload == null) {
            // Roda o OCR Visual ML Kit focado na janela da 99/Uber
            tryVisualOcrScan(nowSec, rideCtx)

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

        // Oferta válida encontrada na árvore de acessibilidade!
        handleRecognizedOffer(detectedPayload, nowSec)
    }

    private fun handleRecognizedOffer(detectedPayload: RideOfferPayload, nowSec: Double) {
        lastValidOfferSeenTimeSec = nowSec
        didSendClearCard = false
        didSendAcceptedForLastOffer = false

        // Agenda limpeza automática para 5s caso o card suma e o mapa fique parado
        mainHandler.removeCallbacks(autoClearRunnable)
        mainHandler.postDelayed(autoClearRunnable, 5000L)

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
        nowSec: Double,
        overlayRect: Rect?
    ): Pair<RideOfferPayload?, String> {
        val collectedLines = mutableListOf<ScreenTextLine>()
        val is99Pkg = pkgName?.lowercase()?.let { it.contains("99") || it.contains("didi") || it.contains("taxis") } == true
        collectTextLines(rootNode, collectedLines, requireVisible = !is99Pkg, depth = 0, overlayRect = overlayRect)
        // Se para outros apps de corrida não achamos "R$", tenta sem filtro de visibilidade também
        if (!is99Pkg && RideScreenParser.isRideAppPackage(pkgName) && collectedLines.none { it.text.contains("R$") }) {
            collectedLines.clear()
            collectTextLines(rootNode, collectedLines, requireVisible = false, depth = 0, overlayRect = overlayRect)
        }
        if (collectedLines.isEmpty()) return Pair(null, "")

        val sortedLines = collectedLines.sortedWith(compareBy<ScreenTextLine> { it.topY }.thenBy { it.leftX })
        val allScreenText = sortedLines.joinToString("\n") { it.text }

        if (RideScreenParser.isInsideOwnAppOrHistoryScreen(allScreenText, pkgName)) {
            return Pair(null, "")
        }

        val cleanCardLines = sortedLines.filter { it.topY > 110 && !RideScreenParser.isSelfOverlayLine(it.text) }
        val payload = RideScreenParser.parseRideCard(cleanCardLines, pkgName, nowSec)
        return Pair(payload, allScreenText)
    }

    private fun collectTextLines(
        node: AccessibilityNodeInfo?,
        output: MutableList<ScreenTextLine>,
        requireVisible: Boolean,
        depth: Int,
        overlayRect: Rect?
    ) {
        if (node == null || depth > 70 || output.size > 750) return
        if (requireVisible && !node.isVisibleToUser) return

        val rect = Rect()
        try { node.getBoundsInScreen(rect) } catch (_: Exception) {}

        // Se o nó estiver dentro da área da nossa pílula flutuante, ignora!
        if (!rect.isEmpty && overlayRect != null && Rect.intersects(rect, overlayRect)) {
            return
        }

        val rawText = node.text?.toString()?.let { normalizeText(it) }
        val rawDesc = node.contentDescription?.toString()?.let { normalizeText(it) }

        val safeTopY = if (rect.top > 0) rect.top else (depth * 14)
        val safeHeight = if (rect.height() > 0) rect.height().coerceAtLeast(12) else 24
        val safeLeftX = if (rect.left >= 0) rect.left else 0

        if (!rawText.isNullOrEmpty()) {
            output.add(ScreenTextLine(text = rawText, topY = safeTopY, height = safeHeight, leftX = safeLeftX))
        }
        if (!rawDesc.isNullOrEmpty() && rawDesc != rawText) {
            output.add(ScreenTextLine(text = rawDesc, topY = safeTopY, height = safeHeight, leftX = safeLeftX))
        }

        val childCount = node.childCount
        for (i in 0 until childCount) {
            val child = try {
                node.getChild(i)
            } catch (_: Exception) {
                null
            }
            if (child != null) {
                collectTextLines(child, output, requireVisible, depth + 1, overlayRect)
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
        if (!didSendClearCard && (nowSec - lastValidOfferSeenTimeSec) >= 4.5) {
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
            card.visibility = View.VISIBLE
            val lp = layoutParams ?: return@post
            val density = resources.displayMetrics.density
            fun dp(value: Int): Int = (value * density).toInt()

            val analysis = AppStateRepository.latestAnalysis.value
            val settings = AppStateRepository.settings.value

            // MODO 1: PÍLULA COMPACTA DISCRETA COM MÉTRICAS DO DIA (Sem poluição visual)
            if (analysis == null) {
                card.setPadding(dp(12), dp(6), dp(12), dp(6))
                card.background = buildRoundedBackground(
                    Color.parseColor("#E6111827"),
                    Color.parseColor("#10B981"),
                    dp(24),
                    dp(1.5f.toInt())
                )
                
                // Métricas do Dia em tempo real (Ganhos Acumulados / Lucro / Corridas Aceitas)
                val acceptedRides = AppStateRepository.acceptedRides.value
                val totalGross = acceptedRides.sumOf { it.offer.fareBRL }
                val totalNet = acceptedRides.sumOf { it.netProfitBRL }
                val acceptedCount = acceptedRides.size
                val targetStr = String.format(Locale("pt", "BR"), "%.2f", settings.targetBRLPerKm)
                
                val statusText = if (acceptedCount > 0) {
                    val grossStr = String.format(Locale("pt", "BR"), "%.2f", totalGross)
                    val netStr = String.format(Locale("pt", "BR"), "%.2f", totalNet)
                    "🟢 Dia: R$ $grossStr ($acceptedCount) • Lucro R$ $netStr"
                } else {
                    "🟢 Dia: R$ 0,00 (0) • Meta R$ $targetStr/km"
                }

                headerBadgeView?.text = statusText
                acceptButtonView?.visibility = View.GONE
                pauseButtonView?.visibility = View.VISIBLE
                metricsRowContainer?.visibility = View.GONE
                footerDetailsView?.visibility = View.GONE

                val targetWidth = dp(308)
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
            val (bgColor, strokeColor) = when (analysis.verdict) {
                RideVerdict.APPROVED -> Pair(Color.parseColor("#064E3B"), Color.parseColor("#34D399"))
                RideVerdict.WARNING -> Pair(Color.parseColor("#78350F"), Color.parseColor("#FBBF24"))
                RideVerdict.REJECTED -> Pair(Color.parseColor("#7F1D1D"), Color.parseColor("#F87171"))
            }

            card.setPadding(dp(14), dp(8), dp(14), dp(8))
            card.background = buildRoundedBackground(bgColor, strokeColor, dp(16), dp(1.5f.toInt()))

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

            kmMetricView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            hourMetricView?.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            kmMetricView?.text = String.format(Locale("pt", "BR"), "R$ %.2f/km", shownKm)
            hourMetricView?.text = String.format(Locale("pt", "BR"), "R$ %.0f/h", shownHour)

            val distDetail = if (analysis.offer.pickupDistanceKm > 0.05 && analysis.offer.tripDistanceKm > 0.05) {
                String.format(
                    Locale("pt", "BR"),
                    "Busca %.1f km • Viagem %.1f km (%d min)",
                    analysis.offer.pickupDistanceKm,
                    analysis.offer.tripDistanceKm,
                    analysis.offer.totalMinutes
                )
            } else {
                String.format(Locale("pt", "BR"), "%.1f km total (%d min)", analysis.offer.totalDistanceKm, analysis.offer.totalMinutes)
            }

            footerDetailsView?.text = String.format(
                Locale("pt", "BR"),
                "Tarifa R$ %.2f • %s • Comb. -R$ %.2f",
                analysis.offer.fareBRL,
                distDetail,
                analysis.fuelCostBRL
            )

            val expandedWidth = dp(315)
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
            val inst = activeInstance ?: return
            inst.showOrUpdateOverlayInternal()
            inst.startHeartbeatIfNeeded()
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
                inst.startHeartbeatIfNeeded()
            }
            return true
        }
    }
}
