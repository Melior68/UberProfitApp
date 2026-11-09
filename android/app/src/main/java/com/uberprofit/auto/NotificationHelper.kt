package com.uberprofit.auto

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import java.util.Locale

class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            NotificationHelper.ACTION_ACCEPT_LAST_RIDE -> {
                AppStateRepository.initIfNeeded(context)
                AppStateRepository.acceptLatestRide(context)
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(NotificationHelper.OFFER_NOTIFICATION_ID)
            }
            NotificationHelper.ACTION_CLEAR_CARD -> {
                AppStateRepository.initIfNeeded(context)
                AppStateRepository.clearActiveCard(context)
            }
        }
    }
}

object NotificationHelper {
    const val CHANNEL_OFFERS_ID = "uber_profit_offers_high_v7"
    const val CHANNEL_SERVICE_ID = "uber_profit_service_v7"
    const val OFFER_NOTIFICATION_ID = 7001
    const val SERVICE_NOTIFICATION_ID = 7002

    const val ACTION_ACCEPT_LAST_RIDE = "com.uberprofit.auto.ACTION_ACCEPT_LAST_RIDE"
    const val ACTION_CLEAR_CARD = "com.uberprofit.auto.ACTION_CLEAR_CARD"

    fun ensureChannels(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val offerChannel = NotificationChannel(
            CHANNEL_OFFERS_ID,
            "Alertas de Ofertas Uber & 99",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Exibe banner rápido no topo quando uma corrida toca na Uber ou 99"
            enableVibration(true)
        }

        val serviceChannel = NotificationChannel(
            CHANNEL_SERVICE_ID,
            "Monitoramento em 2º Plano",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Mantém a janela flutuante e o leitor ativos durante o turno"
            setShowBadge(false)
        }

        nm.createNotificationChannel(offerChannel)
        nm.createNotificationChannel(serviceChannel)
    }

    fun buildForegroundServiceNotification(context: Context): Notification {
        ensureChannels(context)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingOpen = PendingIntent.getActivity(
            context,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(context, CHANNEL_SERVICE_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Uber & 99 Profit Auto Ativo")
            .setContentText("Monitorando ofertas de corrida em tempo real...")
            .setContentIntent(pendingOpen)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    fun sendRideBanner(
        context: Context,
        analysis: RideAnalysis,
        displayMode: PrimaryMetricDisplay
    ) {
        ensureChannels(context)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val shownKm = if (displayMode == PrimaryMetricDisplay.NET) analysis.netPerKm else analysis.grossPerKm
        val shownHour = if (displayMode == PrimaryMetricDisplay.NET) analysis.netPerHour else analysis.grossPerHour

        val kmStr = String.format(Locale("pt", "BR"), "R$ %.2f/km", shownKm)
        val hourStr = String.format(Locale("pt", "BR"), "R$ %.0f/h", shownHour)
        val netStr = String.format(Locale("pt", "BR"), "R$ %.2f", analysis.netProfitBRL)
        val fareStr = String.format(Locale("pt", "BR"), "R$ %.2f", analysis.offer.fareBRL)
        val distStr = String.format(Locale("pt", "BR"), "%.1f km", analysis.offer.totalDistanceKm)
        val fuelStr = String.format(Locale("pt", "BR"), "-R$ %.2f", analysis.fuelCostBRL)

        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingOpen = PendingIntent.getActivity(
            context,
            1,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val acceptIntent = Intent(context, NotificationActionReceiver::class.java).apply {
            action = ACTION_ACCEPT_LAST_RIDE
        }
        val pendingAccept = PendingIntent.getBroadcast(
            context,
            2,
            acceptIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = "${analysis.verdict.emoji} ${analysis.verdict.rawValue} (${analysis.offer.appSource}) • $kmStr • $hourStr"
        val body = "Lucro Livre: $netStr (Comb: $fuelStr) • Tarifa: $fareStr • $distStr (${analysis.offer.totalMinutes} min)"

        val notification = NotificationCompat.Builder(context, CHANNEL_OFFERS_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setAutoCancel(true)
            .setContentIntent(pendingOpen)
            .addAction(
                android.R.drawable.checkbox_on_background,
                "✅ Aceitei essa Corrida (Salvar nos Ganhos)",
                pendingAccept
            )
            .build()

        try {
            nm.notify(OFFER_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
        }
    }
}
