package com.uberprofit.auto

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt

data class RideOfferPayload(
    val appSource: String = "UBER", // "UBER", "99" ou "EXTRA"
    val fareBRL: Double,
    val pickupDistanceKm: Double,
    val tripDistanceKm: Double,
    val totalDistanceKm: Double,
    val pickupMinutes: Int,
    val tripMinutes: Int,
    val totalMinutes: Int,
    val rawRecognizedText: String,
    val timestamp: Double
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("appSource", appSource)
        put("fareBRL", fareBRL)
        put("pickupDistanceKm", pickupDistanceKm)
        put("tripDistanceKm", tripDistanceKm)
        put("totalDistanceKm", totalDistanceKm)
        put("pickupMinutes", pickupMinutes)
        put("tripMinutes", tripMinutes)
        put("totalMinutes", totalMinutes)
        put("rawRecognizedText", rawRecognizedText)
        put("timestamp", timestamp)
    }

    companion object {
        fun fromJson(obj: JSONObject): RideOfferPayload = RideOfferPayload(
            appSource = obj.optString("appSource", "UBER"),
            fareBRL = obj.optDouble("fareBRL", 0.0),
            pickupDistanceKm = obj.optDouble("pickupDistanceKm", 0.0),
            tripDistanceKm = obj.optDouble("tripDistanceKm", 0.0),
            totalDistanceKm = obj.optDouble("totalDistanceKm", 0.0),
            pickupMinutes = obj.optInt("pickupMinutes", 0),
            tripMinutes = obj.optInt("tripMinutes", 1),
            totalMinutes = obj.optInt("totalMinutes", 1),
            rawRecognizedText = obj.optString("rawRecognizedText", ""),
            timestamp = obj.optDouble("timestamp", System.currentTimeMillis() / 1000.0)
        )
    }
}

enum class VisualAlertMode(val rawValue: String, val title: String) {
    NOTIFICATION("NOTIFICATION", "Só Notificação"),
    PIP("PIP", "Só Janela Flutuante"),
    BOTH("BOTH", "Notificação + Flutuante");

    companion object {
        fun fromRaw(raw: String): VisualAlertMode =
            entries.firstOrNull { it.rawValue == raw } ?: BOTH
    }
}

enum class VoiceSpeechStyle(val rawValue: String, val title: String, val description: String) {
    FULL(
        "FULL",
        "Completa (Todas)",
        "Fala R$/km, R$/hora e Lucro Líquido em todas as corridas."
    ),
    COMPACT(
        "COMPACT",
        "Curta e Rápida",
        "Fala apenas R$/km e Lucro Líquido de forma bem rápida."
    ),
    GOOD_ONLY(
        "GOOD_ONLY",
        "Falar Só Boas/Atenção",
        "Fala voz completa nas Boas/Atenção; nas Recusadas dá apenas 1 bipe discreto."
    );

    companion object {
        fun fromRaw(raw: String): VoiceSpeechStyle =
            entries.firstOrNull { it.rawValue == raw } ?: FULL
    }
}

enum class PrimaryMetricDisplay(val rawValue: String, val title: String) {
    GROSS("GROSS", "Valor Bruto (Uber/99)"),
    NET("NET", "Valor Líquido (Livre)");

    companion object {
        fun fromRaw(raw: String): PrimaryMetricDisplay =
            entries.firstOrNull { it.rawValue == raw } ?: GROSS
    }
}

enum class RideVerdict(val rawValue: String, val emoji: String) {
    APPROVED("ACEITAR", "🟢"),
    WARNING("ATENÇÃO", "🟡"),
    REJECTED("RECUSAR", "🔴");

    companion object {
        fun fromRaw(raw: String): RideVerdict =
            entries.firstOrNull { it.rawValue == raw } ?: REJECTED
    }
}

data class RideAnalysis(
    val id: String = UUID.randomUUID().toString(),
    val offer: RideOfferPayload,
    val grossPerKm: Double,
    val grossPerHour: Double,
    val fuelCostBRL: Double,
    val netProfitBRL: Double,
    val netPerKm: Double,
    val netPerHour: Double,
    val verdict: RideVerdict
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("offer", offer.toJson())
        put("grossPerKm", grossPerKm)
        put("grossPerHour", grossPerHour)
        put("fuelCostBRL", fuelCostBRL)
        put("netProfitBRL", netProfitBRL)
        put("netPerKm", netPerKm)
        put("netPerHour", netPerHour)
        put("verdict", verdict.rawValue)
    }

    companion object {
        fun fromJson(obj: JSONObject): RideAnalysis = RideAnalysis(
            id = obj.optString("id", UUID.randomUUID().toString()),
            offer = RideOfferPayload.fromJson(obj.getJSONObject("offer")),
            grossPerKm = obj.optDouble("grossPerKm", 0.0),
            grossPerHour = obj.optDouble("grossPerHour", 0.0),
            fuelCostBRL = obj.optDouble("fuelCostBRL", 0.0),
            netProfitBRL = obj.optDouble("netProfitBRL", 0.0),
            netPerKm = obj.optDouble("netPerKm", 0.0),
            netPerHour = obj.optDouble("netPerHour", 0.0),
            verdict = RideVerdict.fromRaw(obj.optString("verdict", "RECUSAR"))
        )

        fun listToJsonString(list: List<RideAnalysis>): String {
            val arr = JSONArray()
            list.forEach { arr.put(it.toJson()) }
            return arr.toString()
        }

        fun listFromJsonString(json: String?): List<RideAnalysis> {
            if (json.isNullOrBlank()) return emptyList()
            return try {
                val arr = JSONArray(json)
                val result = mutableListOf<RideAnalysis>()
                for (i in 0 until arr.length()) {
                    result.add(fromJson(arr.getJSONObject(i)))
                }
                result
            } catch (_: Exception) {
                emptyList()
            }
        }
    }
}

data class DriverSettings(
    val targetBRLPerKm: Double = 2.00,
    val targetBRLPerHour: Double = 40.00,
    val carConsumptionKmPerLiter: Double = 10.0,
    val fuelPriceBRLPerLiter: Double = 6.35,
    val voiceAlertsEnabled: Boolean = true,
    val evaluateUsingNetProfit: Boolean = false,
    val voiceSpeechStyle: VoiceSpeechStyle = VoiceSpeechStyle.FULL,
    val voiceSpeechRate: Float = 1.05f,
    val visualAlertMode: VisualAlertMode = VisualAlertMode.BOTH,
    val primaryMetricDisplay: PrimaryMetricDisplay = PrimaryMetricDisplay.GROSS,
    val dailyNetGoalBRL: Double = 250.00,
    val extraDailyExpenseBRL: Double = 0.00,
    val autoDetectAcceptedRides: Boolean = true,
    val showQuickGuide: Boolean = true,
    val isShiftReadingEnabled: Boolean = false
) {
    val fuelCostPerKm: Double
        get() = fuelPriceBRLPerLiter / max(carConsumptionKmPerLiter, 1.0)
}

object ProfitCalculator {
    fun evaluate(offer: RideOfferPayload, settings: DriverSettings): RideAnalysis {
        val safeDistanceKm = max(offer.totalDistanceKm, 0.1)
        val safeMinutes = max(offer.totalMinutes.toDouble(), 1.0)
        val safeConsumption = max(settings.carConsumptionKmPerLiter, 1.0)

        val grossPerKm = offer.fareBRL / safeDistanceKm
        val grossPerHour = (offer.fareBRL / safeMinutes) * 60.0

        val litersUsed = safeDistanceKm / safeConsumption
        val fuelCostBRL = litersUsed * settings.fuelPriceBRLPerLiter
        val netProfitBRL = offer.fareBRL - fuelCostBRL

        val netPerKm = netProfitBRL / safeDistanceKm
        val netPerHour = (netProfitBRL / safeMinutes) * 60.0

        val referencePerKm = if (settings.evaluateUsingNetProfit) netPerKm else grossPerKm
        val referencePerHour = if (settings.evaluateUsingNetProfit) netPerHour else grossPerHour

        val meetsKmTarget = referencePerKm >= settings.targetBRLPerKm
        val meetsHourTarget = referencePerHour >= settings.targetBRLPerHour

        val verdict = when {
            meetsKmTarget && meetsHourTarget -> RideVerdict.APPROVED
            meetsKmTarget || meetsHourTarget ||
                (referencePerKm >= settings.targetBRLPerKm * 0.85 &&
                 referencePerHour >= settings.targetBRLPerHour * 0.85) -> RideVerdict.WARNING
            else -> RideVerdict.REJECTED
        }

        return RideAnalysis(
            offer = offer,
            grossPerKm = grossPerKm,
            grossPerHour = grossPerHour,
            fuelCostBRL = fuelCostBRL,
            netProfitBRL = netProfitBRL,
            netPerKm = netPerKm,
            netPerHour = netPerHour,
            verdict = verdict
        )
    }

    fun computeOfferHash(fare: Double, totalKm: Double, totalMin: Int): Int {
        var result = (fare * 100.0).roundToInt()
        result = 31 * result + (totalKm * 10.0).roundToInt()
        result = 31 * result + totalMin
        return result
    }
}
