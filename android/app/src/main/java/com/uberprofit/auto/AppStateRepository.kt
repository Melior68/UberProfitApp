package com.uberprofit.auto

import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.abs

object AppStateRepository {

    private const val PREFS_NAME = "UberProfit_Android_Prefs_V8"
    private const val KEY_ACCEPTED_RIDES = "UberProfit_AcceptedRides_V8"
    private const val KEY_OFFER_HISTORY = "UberProfit_OfferHistory_V8"

    private var prefs: SharedPreferences? = null
    private var voiceManager: VoiceAlertManager? = null

    private val _settings = MutableStateFlow(DriverSettings())
    val settings: StateFlow<DriverSettings> = _settings.asStateFlow()

    private val _latestAnalysis = MutableStateFlow<RideAnalysis?>(null)
    val latestAnalysis: StateFlow<RideAnalysis?> = _latestAnalysis.asStateFlow()

    private val _lastSeenAnalysis = MutableStateFlow<RideAnalysis?>(null)
    val lastSeenAnalysis: StateFlow<RideAnalysis?> = _lastSeenAnalysis.asStateFlow()

    private val _history = MutableStateFlow<List<RideAnalysis>>(emptyList())
    val history: StateFlow<List<RideAnalysis>> = _history.asStateFlow()

    private val _acceptedRides = MutableStateFlow<List<RideAnalysis>>(emptyList())
    val acceptedRides: StateFlow<List<RideAnalysis>> = _acceptedRides.asStateFlow()

    private val _isAccessibilityActive = MutableStateFlow(false)
    val isAccessibilityActive: StateFlow<Boolean> = _isAccessibilityActive.asStateFlow()

    private val _isOverlayActive = MutableStateFlow(false)
    val isOverlayActive: StateFlow<Boolean> = _isOverlayActive.asStateFlow()

    // Diagnóstico: último texto bruto que o leitor enxergou dentro da Uber/99
    private val _lastScreenDump = MutableStateFlow("")
    val lastScreenDump: StateFlow<String> = _lastScreenDump.asStateFlow()

    // Histórico das últimas 5 leituras com R$ (ou ofertas) para que uma janela "Erro de rede" não apague o card
    private val recentRichDumps = ArrayDeque<String>()

    fun setLastScreenDump(dump: String, isRichOrOffer: Boolean = false) {
        if (isRichOrOffer) {
            val timestamp = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
                .format(java.util.Date())
            val entry = "🕒 [$timestamp]\n$dump"
            if (recentRichDumps.firstOrNull()?.substringAfter("\n") != dump) {
                recentRichDumps.addFirst(entry)
                while (recentRichDumps.size > 4) {
                    recentRichDumps.removeLast()
                }
            }
        }
        val combined = buildString {
            appendLine("=== LEITURA ATUAL DA TELA ===")
            appendLine(dump.trim())
            if (recentRichDumps.isNotEmpty()) {
                appendLine()
                appendLine("=== ÚLTIMAS TELAS COM VALORES (R$) CAPTURADAS ===")
                recentRichDumps.forEachIndexed { idx, item ->
                    appendLine("--- Captura #${idx + 1} ---")
                    appendLine(item.trim())
                    appendLine()
                }
            }
        }
        _lastScreenDump.value = combined.take(6500)
    }

    fun initIfNeeded(context: Context) {
        val appCtx = context.applicationContext
        if (prefs == null) {
            prefs = appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            loadFromPrefs()
        }
        if (voiceManager == null) {
            voiceManager = VoiceAlertManager(appCtx)
        }
        refreshServiceStatuses(appCtx)
    }

    fun refreshServiceStatuses(context: Context) {
        val enabledServices = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: ""
        val expectedComponent = "${context.packageName}/${UberProfitAccessibilityService::class.java.canonicalName}"
        val expectedShort = "${context.packageName}/.UberProfitAccessibilityService"
        val isAccEnabled = enabledServices.contains(expectedComponent, ignoreCase = true) ||
            enabledServices.contains(expectedShort, ignoreCase = true) ||
            UberProfitAccessibilityService.isConnectedInstance
        _isAccessibilityActive.value = isAccEnabled
    }

    fun setAccessibilityConnected(connected: Boolean) {
        _isAccessibilityActive.value = connected
    }

    fun setOverlayActive(active: Boolean) {
        _isOverlayActive.value = active
    }

    fun updateSettings(context: Context, transform: (DriverSettings) -> DriverSettings) {
        initIfNeeded(context)
        val updated = transform(_settings.value)
        _settings.value = updated
        saveSettingsToPrefs(updated)

        val current = _latestAnalysis.value
        if (current != null) {
            val reevaluated = ProfitCalculator.evaluate(current.offer, updated)
            _latestAnalysis.value = reevaluated
            _lastSeenAnalysis.value = reevaluated
        }
        if (!updated.isShiftReadingEnabled) {
            _latestAnalysis.value = null
            UberProfitAccessibilityService.hideOverlayFromMasterSwitch()
        } else {
            UberProfitAccessibilityService.refreshIfRunning()
        }
    }

    fun toggleShiftReading(context: Context) {
        initIfNeeded(context)
        refreshServiceStatuses(context)
        if (!_isAccessibilityActive.value) {
            // Se a permissão não foi dada, não permite ligar o turno!
            return
        }
        val newState = !_settings.value.isShiftReadingEnabled
        updateSettings(context) { it.copy(isShiftReadingEnabled = newState) }
        if (newState && _settings.value.visualAlertMode != VisualAlertMode.NOTIFICATION) {
            UberProfitAccessibilityService.showOrUpdateOffer()
        }
    }

    fun processIncomingOffer(context: Context, offer: RideOfferPayload) {
        initIfNeeded(context)
        val currentSettings = _settings.value
        val analysis = ProfitCalculator.evaluate(offer, currentSettings)

        _latestAnalysis.value = analysis
        _lastSeenAnalysis.value = analysis

        val updatedHistory = listOf(analysis) + _history.value.take(79)
        _history.value = updatedHistory
        saveListsToPrefs()

        // 1. Atualiza ou abre a Janela Flutuante via AccessibilityOverlay (sem precisar de SYSTEM_ALERT_WINDOW!)
        if (currentSettings.visualAlertMode != VisualAlertMode.NOTIFICATION) {
            UberProfitAccessibilityService.showOrUpdateOffer()
        }

        // 2. Envia Banner de Notificação no Topo se o modo for NOTIFICATION ou BOTH
        if (currentSettings.visualAlertMode == VisualAlertMode.NOTIFICATION ||
            currentSettings.visualAlertMode == VisualAlertMode.BOTH
        ) {
            NotificationHelper.sendRideBanner(
                context,
                analysis,
                currentSettings.primaryMetricDisplay
            )
        }

        // 3. Fala Alerta de Voz + Bipe
        voiceManager?.announce(analysis, currentSettings)
    }

    fun clearActiveCard(context: Context) {
        _latestAnalysis.value = null
        UberProfitAccessibilityService.refreshIfRunning()
    }

    fun onAutoDetectedRideAccepted(context: Context) {
        initIfNeeded(context)
        if (_settings.value.autoDetectAcceptedRides) {
            acceptLatestRide(context)
        }
        clearActiveCard(context)
    }

    fun isRideAlreadyAccepted(ride: RideAnalysis): Boolean {
        return _acceptedRides.value.any { existing ->
            existing.id == ride.id ||
                (abs(existing.offer.fareBRL - ride.offer.fareBRL) < 0.01 &&
                    abs(existing.offer.totalDistanceKm - ride.offer.totalDistanceKm) < 0.05 &&
                    abs(existing.offer.timestamp - ride.offer.timestamp) < 60.0)
        }
    }

    fun acceptRide(context: Context, ride: RideAnalysis) {
        initIfNeeded(context)
        if (isRideAlreadyAccepted(ride)) return
        _acceptedRides.value = listOf(ride) + _acceptedRides.value
        saveListsToPrefs()
        UberProfitAccessibilityService.refreshIfRunning()
    }

    fun acceptLatestRide(context: Context) {
        val candidate = _latestAnalysis.value ?: _lastSeenAnalysis.value ?: return
        acceptRide(context, candidate)
    }

    fun removeAcceptedRide(context: Context, ride: RideAnalysis) {
        initIfNeeded(context)
        _acceptedRides.value = _acceptedRides.value.filterNot { it.id == ride.id }
        saveListsToPrefs()
    }

    fun clearShiftEarnings(context: Context) {
        initIfNeeded(context)
        _acceptedRides.value = emptyList()
        updateSettings(context) { it.copy(extraDailyExpenseBRL = 0.0) }
        saveListsToPrefs()
    }

    fun clearHistory(context: Context) {
        initIfNeeded(context)
        _history.value = emptyList()
        saveListsToPrefs()
    }

    private fun loadFromPrefs() {
        val p = prefs ?: return
        _settings.value = DriverSettings(
            targetBRLPerKm = p.getFloat("targetBRLPerKm", 2.00f).toDouble(),
            targetBRLPerHour = p.getFloat("targetBRLPerHour", 40.00f).toDouble(),
            carConsumptionKmPerLiter = p.getFloat("carConsumptionKmPerLiter", 10.0f).toDouble(),
            fuelPriceBRLPerLiter = p.getFloat("fuelPriceBRLPerLiter", 6.35f).toDouble(),
            voiceAlertsEnabled = p.getBoolean("voiceAlertsEnabled", true),
            evaluateUsingNetProfit = p.getBoolean("evaluateUsingNetProfit", false),
            voiceSpeechStyle = VoiceSpeechStyle.fromRaw(p.getString("voiceSpeechStyleRaw", "FULL") ?: "FULL"),
            voiceSpeechRate = p.getFloat("voiceSpeechRate", 1.05f),
            visualAlertMode = VisualAlertMode.fromRaw(p.getString("visualAlertModeRaw", "BOTH") ?: "BOTH"),
            primaryMetricDisplay = PrimaryMetricDisplay.fromRaw(p.getString("primaryMetricDisplayRaw", "GROSS") ?: "GROSS"),
            dailyNetGoalBRL = p.getFloat("dailyNetGoalBRL", 250.0f).toDouble(),
            extraDailyExpenseBRL = p.getFloat("extraDailyExpenseBRL", 0.0f).toDouble(),
            autoDetectAcceptedRides = p.getBoolean("autoDetectAcceptedRides", true),
            showQuickGuide = p.getBoolean("showQuickGuide", true),
            isShiftReadingEnabled = p.getBoolean("isShiftReadingEnabled", false)
        )

        val savedAccepted = RideAnalysis.listFromJsonString(p.getString(KEY_ACCEPTED_RIDES, null))
        _acceptedRides.value = savedAccepted

        val savedHist = RideAnalysis.listFromJsonString(p.getString(KEY_OFFER_HISTORY, null))
        _history.value = savedHist
        _lastSeenAnalysis.value = savedHist.firstOrNull()
    }

    private fun saveSettingsToPrefs(s: DriverSettings) {
        prefs?.edit()?.apply {
            putFloat("targetBRLPerKm", s.targetBRLPerKm.toFloat())
            putFloat("targetBRLPerHour", s.targetBRLPerHour.toFloat())
            putFloat("carConsumptionKmPerLiter", s.carConsumptionKmPerLiter.toFloat())
            putFloat("fuelPriceBRLPerLiter", s.fuelPriceBRLPerLiter.toFloat())
            putBoolean("voiceAlertsEnabled", s.voiceAlertsEnabled)
            putBoolean("evaluateUsingNetProfit", s.evaluateUsingNetProfit)
            putString("voiceSpeechStyleRaw", s.voiceSpeechStyle.rawValue)
            putFloat("voiceSpeechRate", s.voiceSpeechRate)
            putString("visualAlertModeRaw", s.visualAlertMode.rawValue)
            putString("primaryMetricDisplayRaw", s.primaryMetricDisplay.rawValue)
            putFloat("dailyNetGoalBRL", s.dailyNetGoalBRL.toFloat())
            putFloat("extraDailyExpenseBRL", s.extraDailyExpenseBRL.toFloat())
            putBoolean("autoDetectAcceptedRides", s.autoDetectAcceptedRides)
            putBoolean("showQuickGuide", s.showQuickGuide)
            putBoolean("isShiftReadingEnabled", s.isShiftReadingEnabled)
            apply()
        }
    }

    private fun saveListsToPrefs() {
        prefs?.edit()?.apply {
            putString(KEY_ACCEPTED_RIDES, RideAnalysis.listToJsonString(_acceptedRides.value))
            putString(KEY_OFFER_HISTORY, RideAnalysis.listToJsonString(_history.value.take(80)))
            apply()
        }
    }
}
