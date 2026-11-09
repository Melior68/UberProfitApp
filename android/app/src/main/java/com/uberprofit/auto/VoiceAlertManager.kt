package com.uberprofit.auto

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

class VoiceAlertManager(context: Context) {

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var isTtsReady = false
    private var focusRequest: AudioFocusRequest? = null

    init {
        initTts()
    }

    private fun initTts() {
        tts = TextToSpeech(appContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                val ptBr = Locale("pt", "BR")
                val result = tts?.setLanguage(ptBr)
                isTtsReady = (result != TextToSpeech.LANG_MISSING_DATA &&
                    result != TextToSpeech.LANG_NOT_SUPPORTED)
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {}
                    override fun onDone(utteranceId: String?) {
                        abandonAudioFocus()
                    }
                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        abandonAudioFocus()
                    }
                })
            }
        }
    }

    fun announce(analysis: RideAnalysis, settings: DriverSettings) {
        if (!settings.voiceAlertsEnabled) return

        // 1. Toca bipe imediato e libera o recurso nativo após 260ms (evita vazamento de AudioTrack!)
        playVerdictBeepSafe(analysis.verdict)

        // 2. Se o motorista escolheu "Falar Só Boas/Atenção", nas recusadas toca apenas o bipe curto
        if (settings.voiceSpeechStyle == VoiceSpeechStyle.GOOD_ONLY &&
            analysis.verdict == RideVerdict.REJECTED
        ) {
            return
        }

        if (!isTtsReady) return

        requestDuckingAudioFocus()

        val phrase = buildSpeechPhrase(analysis, settings)
        tts?.setSpeechRate(settings.voiceSpeechRate.coerceIn(0.75f, 1.50f))
        tts?.setPitch(if (analysis.verdict == RideVerdict.APPROVED) 1.06f else 0.96f)
        tts?.speak(phrase, TextToSpeech.QUEUE_FLUSH, null, "UBER_PROFIT_UTTERANCE")
    }

    private fun playVerdictBeepSafe(verdict: RideVerdict) {
        try {
            val toneGen = ToneGenerator(AudioManager.STREAM_MUSIC, 95)
            val toneType = when (verdict) {
                RideVerdict.APPROVED -> ToneGenerator.TONE_PROP_ACK
                RideVerdict.WARNING -> ToneGenerator.TONE_PROP_BEEP
                RideVerdict.REJECTED -> ToneGenerator.TONE_PROP_NACK
            }
            toneGen.startTone(toneType, 200)
            mainHandler.postDelayed({
                try {
                    toneGen.release()
                } catch (_: Exception) {
                }
            }, 280L)
        } catch (_: Exception) {
        }
    }

    private fun buildSpeechPhrase(analysis: RideAnalysis, settings: DriverSettings): String {
        val kmValue = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.NET) {
            analysis.netPerKm
        } else {
            analysis.grossPerKm
        }
        val hourValue = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.NET) {
            analysis.netPerHour
        } else {
            analysis.grossPerHour
        }

        val safeKm = max(kmValue, 0.0)
        val reais = safeKm.toInt()
        val centavos = ((safeKm - reais) * 100.0).roundToInt()
        val horaInt = max(hourValue, 0.0).roundToInt()
        val lucroInt = analysis.netProfitBRL.roundToInt()

        val kmFormatted = if (centavos > 0) {
            "$reais e $centavos por quilômetro"
        } else {
            "$reais reais por quilômetro"
        }

        if (settings.voiceSpeechStyle == VoiceSpeechStyle.COMPACT) {
            return when (analysis.verdict) {
                RideVerdict.APPROVED -> "Boa! $kmFormatted. Lucro $lucroInt."
                RideVerdict.WARNING -> "Atenção! $kmFormatted."
                RideVerdict.REJECTED -> "Recusar! $kmFormatted."
            }
        }

        return when (analysis.verdict) {
            RideVerdict.APPROVED -> "Boa! $kmFormatted. $horaInt por hora. Lucro $lucroInt reais."
            RideVerdict.WARNING -> "Atenção! $kmFormatted. $horaInt por hora."
            RideVerdict.REJECTED -> "Recusar! $kmFormatted."
        }
    }

    private fun requestDuckingAudioFocus() {
        try {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attrs)
                .setAcceptsDelayedFocusGain(false)
                .setOnAudioFocusChangeListener { }
                .build()
            focusRequest = req
            audioManager.requestAudioFocus(req)
        } catch (_: Exception) {
        }
    }

    private fun abandonAudioFocus() {
        try {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } catch (_: Exception) {
        }
    }
}
