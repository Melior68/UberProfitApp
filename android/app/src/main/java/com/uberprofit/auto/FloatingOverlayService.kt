package com.uberprofit.auto

import android.annotation.SuppressLint
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import java.util.Locale
import kotlin.math.abs

class FloatingOverlayService : Service() {

    private var windowManager: WindowManager? = null
    private var rootContainer: LinearLayout? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    private var headerBadgeView: TextView? = null
    private var kmMetricView: TextView? = null
    private var hourMetricView: TextView? = null
    private var footerDetailsView: TextView? = null
    private var acceptButtonView: TextView? = null
    private var closeButtonView: TextView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        AppStateRepository.initIfNeeded(this)
        startForegroundCompat()
        if (Settings.canDrawOverlays(this)) {
            createFloatingView()
            AppStateRepository.setOverlayActive(true)
            updateOverlayContent()
        } else {
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_OVERLAY -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                if (!Settings.canDrawOverlays(this)) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (rootContainer == null) {
                    createFloatingView()
                }
                AppStateRepository.setOverlayActive(true)
                updateOverlayContent()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        removeFloatingView()
        AppStateRepository.setOverlayActive(false)
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val notification = NotificationHelper.buildForegroundServiceNotification(this)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NotificationHelper.SERVICE_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NotificationHelper.SERVICE_NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun createFloatingView() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = wm

        val density = resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density).toInt()

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = buildRoundedBackground(Color.parseColor("#141923"), Color.parseColor("#00BCD4"), dp(18), dp(2))
        }

        // Linha Superior: Badge + Botão Aceitei + Botão Fechar
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
                AppStateRepository.acceptLatestRide(this@FloatingOverlayService)
                updateOverlayContent()
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
                    AppStateRepository.clearActiveCard(this@FloatingOverlayService)
                } else {
                    stopSelf()
                }
            }
        }
        closeButtonView = closeBtn

        topRow.addView(badge)
        topRow.addView(acceptBtn)
        topRow.addView(closeBtn)

        // Linha do Meio: R$/km e R$/h gigantes
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

        // Linha Inferior: Resumo de Tarifa, KM, Tempo e Gasolina
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
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = 0
            y = dp(78)
        }
        layoutParams = params

        // Suporte a arrastar a janela flutuante com o dedo para qualquer posição da tela
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
        } catch (_: Exception) {
        }
    }

    private fun updateOverlayContent() {
        val card = rootContainer ?: return
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
            return
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

    private fun removeFloatingView() {
        val view = rootContainer ?: return
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
        }
        rootContainer = null
    }

    companion object {
        const val ACTION_SHOW_OR_UPDATE = "com.uberprofit.auto.ACTION_SHOW_OR_UPDATE"
        const val ACTION_STOP_OVERLAY = "com.uberprofit.auto.ACTION_STOP_OVERLAY"

        fun showOrUpdateOffer(context: Context) {
            if (!Settings.canDrawOverlays(context)) return
            val intent = Intent(context, FloatingOverlayService::class.java).apply {
                action = ACTION_SHOW_OR_UPDATE
            }
            try {
                context.startForegroundService(intent)
            } catch (_: Exception) {
            }
        }

        fun refreshIfRunning(context: Context) {
            if (!AppStateRepository.isOverlayActive.value) return
            showOrUpdateOffer(context)
        }

        fun toggleOverlay(context: Context) {
            if (AppStateRepository.isOverlayActive.value) {
                val stopIntent = Intent(context, FloatingOverlayService::class.java).apply {
                    action = ACTION_STOP_OVERLAY
                }
                context.startService(stopIntent)
            } else {
                showOrUpdateOffer(context)
            }
        }
    }
}
