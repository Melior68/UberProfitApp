package com.uberprofit.auto

import java.util.regex.Pattern
import kotlin.math.abs
import kotlin.math.max

data class ScreenTextLine(
    val text: String,
    val topY: Int,
    val leftX: Int = 0,
    val height: Int
)

object RideScreenParser {

    // Aceita "R$ 22,80", "R$22.80", "RS 15,00" e também quando o R$ está separado por espaço/quebra
    private val pricePattern: Pattern = Pattern.compile(
        """(?<!\+)(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)""",
        Pattern.CASE_INSENSITIVE
    )

    // Formato Uber e 99 Pop tradicional: "3 min (0.8 km)" ou "8 min (3,2 km)" ou "1 h 5 min (42.1 km)"
    private val stepOutsideParenPattern: Pattern = Pattern.compile(
        """(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*\(\s*(\d{1,4}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)""",
        Pattern.CASE_INSENSITIVE
    )

    // Formato 99 Negocia / Solicitações: "(3 min 1 km)" ou "(19 min 9,2 km)"
    private val stepInsideParenPattern: Pattern = Pattern.compile(
        """\(\s*(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s+(\d{1,4}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)""",
        Pattern.CASE_INSENSITIVE
    )

    // Linha de resumo da Uber: "15 min • 5.4 km • Est. de R$1,91/km"
    private val uberSummaryPattern: Pattern = Pattern.compile(
        """(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*[•·\-]\s*(\d{1,4}(?:[.,]\d{1,2})?)\s*(km|m)\b""",
        Pattern.CASE_INSENSITIVE
    )

    // Padrão da 99 quando o card exibe "R$2,04/km" ou "R$ 2,05/km" logo abaixo do preço
    private val ratePerKmPattern: Pattern = Pattern.compile(
        """(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))\s*/\s*km""",
        Pattern.CASE_INSENSITIVE
    )

    // Pacotes de sistema ou apps comuns que NUNCA devem ser lidos se não houver sobreposição da Uber/99
    private val ignoredPackages = setOf(
        "com.uberprofit.auto",
        "com.whatsapp",
        "com.whatsapp.w4b",
        "com.instagram.android",
        "com.facebook.katana",
        "com.google.android.youtube",
        "com.nu.production",
        "br.com.intermedium",
        "com.itau",
        "com.bradesco",
        "com.santander.app",
        "br.com.bb.android",
        "br.gov.caixa.tem"
    )

    fun isIgnoredPackage(packageName: String?): Boolean {
        if (packageName.isNullOrBlank()) return false
        return ignoredPackages.contains(packageName.lowercase())
    }

    /** Pacotes da Uber Driver (com.ubercab.driver), 99 Motorista (com.app99.driver / com.taxis99) e DiDi. */
    fun isRideAppPackage(packageName: String?): Boolean {
        if (packageName.isNullOrBlank()) return false
        val p = packageName.lowercase()
        if (p == "com.uberprofit.auto") return false
        return p.contains("uber") || p.contains("99") || p.contains("didi") || p.contains("taxis")
    }

    fun isInsideOwnAppOrHistoryScreen(screenText: String, packageName: String?): Boolean {
        if (packageName == "com.uberprofit.auto") return true

        val upper = screenText.uppercase()
        // 1. Detecta se a tela aberta é o próprio app Uber & 99 Profit Auto
        if (upper.contains("UBER & 99 PROFIT AUTO") ||
            upper.contains("METAS & CARRO") ||
            upper.contains("MONITORAMENTO AO VIVO") ||
            upper.contains("OFERTAS REGISTRADAS") ||
            upper.contains("CORRIDAS ACEITAS") ||
            upper.contains("GANHOS DO TURNO") ||
            upper.contains("LUCRO LIVRE NO BOLSO") ||
            upper.contains("LANÇAR CORRIDA") ||
            upper.contains("TESTAR FUNCIONAMENTO") ||
            upper.contains("SIMULAR CORRIDA") ||
            upper.contains("DIAGNÓSTICO DO LEITOR") ||
            upper.contains("DESLIGAR / PAUSAR LEITOR") ||
            upper.contains("LIGAR LEITOR")
        ) {
            return true
        }

        // 2. Detecta se o motorista está olhando o histórico de corridas/ganhos passados dentro da Uber ou da 99
        if (upper.contains("HISTÓRICO DE VIAGENS") ||
            upper.contains("HISTÓRICO DE CORRIDAS") ||
            upper.contains("DETALHES DA VIAGEM") ||
            upper.contains("DETALHES DOS GANHOS") ||
            upper.contains("RESUMO DE GANHOS") ||
            upper.contains("VIAGEM CONCLUÍDA") ||
            upper.contains("CORRIDA FINALIZADA") ||
            upper.contains("EXTRATO DE GANHOS") ||
            upper.contains("ATIVIDADE DE GANHOS")
        ) {
            return true
        }

        return false
    }

    fun isSelfOverlayLine(line: String): Boolean {
        val upper = line.uppercase()
        return upper.contains("PROFIT ATIVO") ||
            upper.contains("UBERPROFIT") ||
            upper.contains("LUCRO R$") ||
            upper.contains("LUCRO LIVRE") ||
            upper.contains("COMB. -R$") ||
            upper.contains("GASOLINA: -R$") ||
            upper.contains("KM TOTAL") ||
            upper.contains("MONITORANDO OFERTAS") ||
            upper.contains("ACEITEI CORRIDA") ||
            upper.contains("ACEITEI") ||
            upper.contains("TARIFA R$") ||
            upper.contains("RECUSAR") ||
            upper.contains("ATENÇÃO") ||
            upper.contains("ATENCAO") ||
            upper.contains("R$ /KM") ||
            upper.contains("R$ /H")
    }

    fun isAcceptedTripScreen(allScreenText: String): Boolean {
        val upper = allScreenText.uppercase()
        return upper.contains("INICIAR VIAGEM") ||
            upper.contains("INICIAR CORRIDA") ||
            upper.contains("IR PARA O EMBARQUE") ||
            upper.contains("A CAMINHO DO") ||
            upper.contains("CHEGUEI NO LOCAL") ||
            upper.contains("CHEGUEI AO LOCAL") ||
            upper.contains("DESLIZE PARA INICIAR") ||
            upper.contains("AGUARDANDO PASSAGEIRO") ||
            upper.contains("BUSCAR PASSAGEIRO") ||
            upper.contains("ENCONTRAR COM") ||
            upper.contains("CANCELAR VIAGEM") ||
            upper.contains("CANCELAR CORRIDA")
    }

    /**
     * Junta nós de texto que estão alinhados horizontalmente na mesma linha da tela
     * (por exemplo, quando a Uber coloca "R$" em um TextView e "22,80" no TextView ao lado).
     */
    fun mergeSameRowLines(rawLines: List<ScreenTextLine>): List<ScreenTextLine> {
        if (rawLines.isEmpty()) return emptyList()
        val sorted = rawLines.sortedWith(compareBy<ScreenTextLine> { it.topY }.thenBy { it.leftX })
        val merged = mutableListOf<ScreenTextLine>()

        for (item in sorted) {
            val last = merged.lastOrNull()
            if (last != null && abs(item.topY - last.topY) <= 18) {
                if (!last.text.contains(item.text)) {
                    merged[merged.lastIndex] = last.copy(
                        text = "${last.text} ${item.text}".trim(),
                        height = max(last.height, item.height)
                    )
                }
            } else {
                merged.add(item)
            }
        }
        return merged
    }

    fun parseRideCard(
        lines: List<ScreenTextLine>,
        packageName: String?,
        timestamp: Double
    ): RideOfferPayload? {
        if (lines.isEmpty()) return null

        val mergedLines = mergeSameRowLines(lines)
        val combinedLines = (mergedLines + lines).distinctBy { "${it.topY}_${it.text}" }
        val fullText = mergedLines.joinToString("\n") { it.text }
        val lowerFull = fullText.lowercase()
        val pkgLower = (packageName ?: "").lowercase()

        val isCollapsed99Drawer = (lowerFull.contains("solicitações") ||
            lowerFull.contains("solicitacoes") ||
            lowerFull.contains("buscando")) &&
            !lowerFull.contains("escolher") &&
            !lowerFull.contains("pgto") &&
            !lowerFull.contains("toque abaixo") &&
            !lowerFull.contains("/km")

        val is99Card = pkgLower.contains("99") ||
            pkgLower.contains("didi") ||
            isCollapsed99Drawer ||
            lowerFull.contains("99pop") ||
            lowerFull.contains("99plus") ||
            lowerFull.contains("99") ||
            lowerFull.contains("pgto") ||
            lowerFull.contains("tarifa base") ||
            lowerFull.contains("cpf verif") ||
            lowerFull.contains("perfil premium") ||
            lowerFull.contains("negocia") ||
            lowerFull.contains("poupa")

        val appSource = if (is99Card) "99" else "UBER"

        // 1. Extrai a Tarifa Principal em Reais
        val fare = extractMainFareBRL(combinedLines, fullText) ?: return null
        if (fare < 4.5 || fare > 950.0) return null

        // 2. Extrai Distâncias e Tempos
        val stepsResult = extractStructuredSteps(fullText, fare)

        // Proteção contra a gaveta recolhida "Solicitações / Buscando" da 99 com segunda linha cortada
        if (isCollapsed99Drawer && stepsResult.stepCount < 2) {
            return null
        }

        if (stepsResult.totalKm < 0.3 || stepsResult.totalMin < 1) {
            return null
        }

        return RideOfferPayload(
            appSource = appSource,
            fareBRL = fare,
            pickupDistanceKm = stepsResult.pickupKm,
            tripDistanceKm = stepsResult.tripKm,
            totalDistanceKm = stepsResult.totalKm,
            pickupMinutes = stepsResult.pickupMin,
            tripMinutes = stepsResult.tripMin,
            totalMinutes = stepsResult.totalMin,
            rawRecognizedText = fullText,
            timestamp = timestamp
        )
    }

    private fun extractMainFareBRL(lines: List<ScreenTextLine>, fullText: String): Double? {
        val candidates = mutableListOf<Pair<Double, Int>>()

        for (line in lines) {
            val lower = line.text.lowercase()
            if (lower.contains("incluíd") ||
                lower.contains("incluid") ||
                lower.contains("incl.") ||
                lower.contains("tarifa base") ||
                lower.contains("dinâmica") ||
                lower.contains("dinamica") ||
                lower.contains("prioritária") ||
                lower.contains("prioritaria") ||
                lower.contains("est. de") ||
                lower.contains("/km") ||
                lower.contains("/h") ||
                lower.contains("lucro") ||
                lower.contains("comb") ||
                lower.contains("meta ")
            ) {
                continue
            }

            val matcher = pricePattern.matcher(line.text)
            while (matcher.find()) {
                val rawVal = matcher.group(1)?.replace(",", ".") ?: continue
                val value = rawVal.toDoubleOrNull() ?: continue
                if (value in 4.5..950.0) {
                    candidates.add(value to max(line.height, 10))
                }
            }
        }

        if (candidates.isEmpty()) {
            // Fallback caso "R$" esteja em uma linha e o número na linha imediatamente seguinte
            val flatText = fullText.replace("\n", " ")
            val matcher = pricePattern.matcher(flatText)
            while (matcher.find()) {
                val rawVal = matcher.group(1)?.replace(",", ".") ?: continue
                val value = rawVal.toDoubleOrNull() ?: continue
                if (value in 4.5..950.0) {
                    candidates.add(value to 20)
                }
            }
        }

        if (candidates.isEmpty()) return null
        val maxHeight = candidates.maxOf { it.second }
        val prominent = candidates.filter { it.second >= (maxHeight * 0.60).toInt() }
        return (prominent.maxOfOrNull { it.first }) ?: candidates.maxOf { it.first }
    }

    private data class StepsResult(
        val pickupKm: Double,
        val tripKm: Double,
        val totalKm: Double,
        val pickupMin: Int,
        val tripMin: Int,
        val totalMin: Int,
        val stepCount: Int
    )

    private fun extractStructuredSteps(fullText: String, fareBRL: Double): StepsResult {
        var summaryResult: Pair<Int, Double>? = null
        val summaryMatcher = uberSummaryPattern.matcher(fullText)
        if (summaryMatcher.find()) {
            val hours = summaryMatcher.group(1)?.toIntOrNull() ?: 0
            val mins = summaryMatcher.group(2)?.toIntOrNull() ?: 0
            val distVal = summaryMatcher.group(3)?.replace(",", ".")?.toDoubleOrNull() ?: 0.0
            val unit = summaryMatcher.group(4)?.lowercase() ?: "km"
            val km = if (unit == "m") distVal / 1000.0 else distVal
            val totalMins = (hours * 60) + mins
            if (km > 0 && totalMins > 0) {
                summaryResult = totalMins to km
            }
        }

        val steps = mutableListOf<Pair<Int, Double>>()
        for (pattern in listOf(stepOutsideParenPattern, stepInsideParenPattern)) {
            val matcher = pattern.matcher(fullText)
            while (matcher.find()) {
                val hours = matcher.group(1)?.toIntOrNull() ?: 0
                val mins = matcher.group(2)?.toIntOrNull() ?: continue
                val distVal = matcher.group(3)?.replace(",", ".")?.toDoubleOrNull() ?: continue
                val unit = matcher.group(4)?.lowercase() ?: "km"
                val distKm = if (unit == "m") distVal / 1000.0 else distVal
                val totalMins = (hours * 60) + mins
                if (distKm > 0 && totalMins > 0) {
                    steps.add(totalMins to distKm)
                }
            }
        }

        // Remove passos duplicados idênticos na mesma leitura
        val uniqueSteps = steps.distinct()

        if (uniqueSteps.size >= 2) {
            val pMin = uniqueSteps[0].first
            val pKm = uniqueSteps[0].second
            val tMin = uniqueSteps.drop(1).sumOf { it.first }
            val tKm = uniqueSteps.drop(1).sumOf { it.second }
            val sumKm = pKm + tKm
            val sumMin = pMin + tMin

            if (summaryResult != null && summaryResult.second > sumKm) {
                return StepsResult(
                    pickupKm = pKm,
                    tripKm = summaryResult.second - pKm,
                    totalKm = summaryResult.second,
                    pickupMin = pMin,
                    tripMin = max(summaryResult.first - pMin, 1),
                    totalMin = summaryResult.first,
                    stepCount = uniqueSteps.size
                )
            }
            return StepsResult(pKm, tKm, sumKm, pMin, tMin, sumMin, uniqueSteps.size)
        }

        if (summaryResult != null) {
            val firstStep = uniqueSteps.firstOrNull()
            if (firstStep != null && summaryResult.second > firstStep.second) {
                val tripKm = summaryResult.second - firstStep.second
                val tripMin = max(summaryResult.first - firstStep.first, 1)
                return StepsResult(
                    pickupKm = firstStep.second,
                    tripKm = tripKm,
                    totalKm = summaryResult.second,
                    pickupMin = firstStep.first,
                    tripMin = tripMin,
                    totalMin = summaryResult.first,
                    stepCount = 2
                )
            }
            return StepsResult(0.0, summaryResult.second, summaryResult.second, 0, summaryResult.first, summaryResult.first, 2)
        }

        val onlyStep = uniqueSteps.firstOrNull()
        if (onlyStep != null) {
            return StepsResult(0.0, onlyStep.second, onlyStep.second, 0, onlyStep.first, onlyStep.first, 1)
        }

        // Fallback para cards da 99 onde o Android retorna apenas "R$17,50" e "R$2,04/km"
        val rateMatcher = ratePerKmPattern.matcher(fullText)
        if (rateMatcher.find() && fareBRL > 0) {
            val ratePerKm = rateMatcher.group(1)?.replace(",", ".")?.toDoubleOrNull() ?: 0.0
            if (ratePerKm >= 0.4) {
                val estTotalKm = (fareBRL / ratePerKm).coerceIn(0.5, 250.0)
                val estTotalMin = max((estTotalKm * 2.4).toInt(), 3)
                return StepsResult(0.0, estTotalKm, estTotalKm, 0, estTotalMin, estTotalMin, 2)
            }
        }

        return StepsResult(0.0, 0.0, 0.0, 0, 0, 0, 0)
    }
}
