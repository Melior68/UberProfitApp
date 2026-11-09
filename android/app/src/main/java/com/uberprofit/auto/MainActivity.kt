package com.uberprofit.auto

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

enum class AppSectionTab(val title: String, val icon: ImageVector) {
    OPERATION("Painel", Icons.Default.DirectionsCar),
    EARNINGS("Ganhos", Icons.Default.AttachMoney),
    GOALS("Metas", Icons.Default.Tune),
    CUSTOMIZE("Alertas", Icons.Default.NotificationsActive),
    HISTORY("Histórico", Icons.Default.History)
}

class MainActivity : ComponentActivity() {

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppStateRepository.initIfNeeded(this)
        NotificationHelper.ensureChannels(this)
        requestNotificationPermissionIfNeeded()

        setContent {
            val darkColorScheme = darkColorScheme(
                primary = Color(0xFF3B82F6),
                secondary = Color(0xFF10B981),
                background = Color(0xFF0B0F17),
                surface = Color(0xFF161E2E),
                surfaceVariant = Color(0xFF222D42)
            )
            MaterialTheme(colorScheme = darkColorScheme) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    UberProfitMainScreen(
                        onOpenAccessibilitySettings = { openAccessibilitySettings() },
                        onToggleOrRequestOverlay = { toggleOrRequestOverlay() },
                        onOpenAppDetailsSettings = { openAppDetailsSettings() }
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        AppStateRepository.refreshServiceStatuses(this)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
    }

    private fun openAccessibilitySettings() {
        try {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        } catch (_: Exception) {
        }
    }

    private fun openAppDetailsSettings() {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun toggleOrRequestOverlay() {
        val toggled = UberProfitAccessibilityService.toggleOverlay()
        if (!toggled) {
            openAccessibilitySettings()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UberProfitMainScreen(
    onOpenAccessibilitySettings: () -> Unit,
    onToggleOrRequestOverlay: () -> Unit,
    onOpenAppDetailsSettings: () -> Unit
) {
    val context = LocalContext.current
    val settings by AppStateRepository.settings.collectAsState()
    val latestAnalysis by AppStateRepository.latestAnalysis.collectAsState()
    val lastSeenAnalysis by AppStateRepository.lastSeenAnalysis.collectAsState()
    val history by AppStateRepository.history.collectAsState()
    val acceptedRides by AppStateRepository.acceptedRides.collectAsState()
    val isAccessibilityActive by AppStateRepository.isAccessibilityActive.collectAsState()
    val isOverlayActive by AppStateRepository.isOverlayActive.collectAsState()

    var selectedTab by remember { mutableStateOf(AppSectionTab.OPERATION) }
    var showAddManualRideDialog by remember { mutableStateOf(false) }
    var selectedItemForOCRDebug by remember { mutableStateOf<RideAnalysis?>(null) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(10.dp)
                                .clip(CircleShape)
                                .background(
                                    when {
                                        !isAccessibilityActive -> Color(0xFFF59E0B)
                                        !settings.isShiftReadingEnabled -> Color(0xFFEF4444)
                                        else -> Color(0xFF10B981)
                                    }
                                )
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "Uber & 99 Profit Auto",
                            fontWeight = FontWeight.Black,
                            fontSize = 18.5.sp
                        )
                    }
                },
                actions = {
                    IconButton(onClick = {
                        AppStateRepository.updateSettings(context) {
                            it.copy(showQuickGuide = !it.showQuickGuide)
                        }
                        selectedTab = AppSectionTab.OPERATION
                    }) {
                        Icon(
                            imageVector = Icons.Default.HelpOutline,
                            contentDescription = "Como Funciona"
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color(0xFF121824),
                    titleContentColor = Color.White,
                    actionIconContentColor = Color(0xFF60A5FA)
                )
            )
        },
        containerColor = Color(0xFF0B0F17)
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
        ) {
            // Barra de 5 Abas
            CategoryTabBar(
                selectedTab = selectedTab,
                acceptedCount = acceptedRides.size,
                onSelectTab = { selectedTab = it }
            )

            // Conteúdo rolável da Aba selecionada
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                when (selectedTab) {
                    AppSectionTab.OPERATION -> OperationTabView(
                        settings = settings,
                        latestAnalysis = latestAnalysis,
                        lastSeenAnalysis = lastSeenAnalysis,
                        history = history,
                        acceptedRides = acceptedRides,
                        isAccessibilityActive = isAccessibilityActive,
                        isOverlayActive = isOverlayActive,
                        onOpenAccessibilitySettings = onOpenAccessibilitySettings,
                        onToggleOrRequestOverlay = onToggleOrRequestOverlay,
                        onOpenAppDetailsSettings = onOpenAppDetailsSettings,
                        onNavigateToTab = { selectedTab = it }
                    )
                    AppSectionTab.EARNINGS -> EarningsTabView(
                        settings = settings,
                        latestAnalysis = latestAnalysis,
                        lastSeenAnalysis = lastSeenAnalysis,
                        acceptedRides = acceptedRides,
                        onOpenManualRideDialog = { showAddManualRideDialog = true }
                    )
                    AppSectionTab.GOALS -> GoalsAndVehicleTabView(
                        settings = settings
                    )
                    AppSectionTab.CUSTOMIZE -> CustomizationTabView(
                        settings = settings
                    )
                    AppSectionTab.HISTORY -> HistoryTabView(
                        history = history,
                        acceptedRides = acceptedRides,
                        onInspectOCR = { selectedItemForOCRDebug = it }
                    )
                }
            }
        }
    }

    if (showAddManualRideDialog) {
        AddManualRideDialog(
            settings = settings,
            onDismiss = { showAddManualRideDialog = false }
        )
    }

    selectedItemForOCRDebug?.let { item ->
        OCRDebugDialog(
            item = item,
            onDismiss = { selectedItemForOCRDebug = null }
        )
    }
}

@Composable
private fun CategoryTabBar(
    selectedTab: AppSectionTab,
    acceptedCount: Int,
    onSelectTab: (AppSectionTab) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Color(0xFF121824))
            .padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        AppSectionTab.entries.forEach { tab ->
            val isSelected = (selectedTab == tab)
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (isSelected) Color(0xFF3B82F6).copy(alpha = 0.22f) else Color.Transparent)
                    .clickable { onSelectTab(tab) }
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(3.dp)
                ) {
                    Box {
                        Icon(
                            imageVector = tab.icon,
                            contentDescription = tab.title,
                            tint = if (isSelected) Color(0xFF60A5FA) else Color(0xFF9CA3AF),
                            modifier = Modifier.size(20.dp)
                        )
                        if (tab == AppSectionTab.EARNINGS && acceptedCount > 0) {
                            Box(
                                modifier = Modifier
                                    .offset(x = 12.dp, y = (-6).dp)
                                    .clip(CircleShape)
                                    .background(Color(0xFF10B981))
                                    .padding(horizontal = 5.dp, vertical = 1.dp)
                            ) {
                                Text(
                                    text = "$acceptedCount",
                                    color = Color.White,
                                    fontSize = 9.sp,
                                    fontWeight = FontWeight.Black
                                )
                            }
                        }
                    }
                    Text(
                        text = tab.title,
                        color = if (isSelected) Color(0xFF60A5FA) else Color(0xFF9CA3AF),
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1
                    )
                }
            }
        }
    }
}

// MARK: - ABA 1: PAINEL DE OPERAÇÃO
@Composable
private fun OperationTabView(
    settings: DriverSettings,
    latestAnalysis: RideAnalysis?,
    lastSeenAnalysis: RideAnalysis?,
    history: List<RideAnalysis>,
    acceptedRides: List<RideAnalysis>,
    isAccessibilityActive: Boolean,
    isOverlayActive: Boolean,
    onOpenAccessibilitySettings: () -> Unit,
    onToggleOrRequestOverlay: () -> Unit,
    onOpenAppDetailsSettings: () -> Unit,
    onNavigateToTab: (AppSectionTab) -> Unit
) {
    val context = LocalContext.current

    if (settings.showQuickGuide) {
        QuickHowItWorksCard(
            onClose = {
                AppStateRepository.updateSettings(context) { it.copy(showQuickGuide = false) }
            }
        )
    }

    LivePreviewSection(
        analysis = latestAnalysis,
        settings = settings,
        isAccessibilityActive = isAccessibilityActive
    )

    val candidate = latestAnalysis ?: lastSeenAnalysis
    if (candidate != null) {
        QuickAcceptLastRideBar(
            item = candidate,
            alreadyAccepted = AppStateRepository.isRideAlreadyAccepted(candidate),
            onAccept = { AppStateRepository.acceptRide(context, candidate) }
        )
    }

    ShiftControlsSection(
        settings = settings,
        isAccessibilityActive = isAccessibilityActive,
        isOverlayActive = isOverlayActive,
        onOpenAccessibilitySettings = onOpenAccessibilitySettings,
        onToggleOrRequestOverlay = onToggleOrRequestOverlay,
        onOpenAppDetailsSettings = onOpenAppDetailsSettings,
        onNavigateToCustomize = { onNavigateToTab(AppSectionTab.CUSTOMIZE) }
    )

    ShiftStatsSection(
        history = history,
        acceptedCount = acceptedRides.size,
        onOpenEarnings = { onNavigateToTab(AppSectionTab.EARNINGS) }
    )

    TestSimulationSection(
        onSimulateOffer = { offer ->
            AppStateRepository.processIncomingOffer(context, offer)
        }
    )
}

@Composable
private fun QuickHowItWorksCard(onClose: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF3B82F6).copy(alpha = 0.14f))
            .border(1.dp, Color(0xFF3B82F6).copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = null,
                tint = Color(0xFF60A5FA),
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = "Como Usar no Dia a Dia (3 Passos)",
                color = Color(0xFF60A5FA),
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp,
                modifier = Modifier.weight(1f)
            )
            IconButton(
                onClick = onClose,
                modifier = Modifier.size(22.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = "Fechar",
                    tint = Color(0xFF9CA3AF)
                )
            }
        }

        Text(
            text = "1. Toque em \"1. Autorizar App\" uma única vez e ligue a Acessibilidade do Uber & 99 Profit.",
            color = Color.White.copy(alpha = 0.92f),
            fontSize = 12.sp
        )
        Text(
            text = "2. Quando for rodar, deixe o botão \"LIGAR LEITOR\" ativo. Uma Pílula Compacta discreta ficará no topo e só se abrirá quando tocar corrida!",
            color = Color.White.copy(alpha = 0.92f),
            fontSize = 12.sp
        )
        Text(
            text = "3. Parou de trabalhar? Toque no botão \"⏸\" da pílula ou em \"DESLIGAR LEITOR\" para pausar tudo.",
            color = Color.White.copy(alpha = 0.92f),
            fontSize = 12.sp
        )
    }
}

@Composable
private fun LivePreviewSection(
    analysis: RideAnalysis?,
    settings: DriverSettings,
    isAccessibilityActive: Boolean
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(
                imageVector = Icons.Default.Sensors,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = "Monitoramento ao Vivo",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp,
                modifier = Modifier.weight(1f)
            )
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            !isAccessibilityActive -> Color(0xFFF59E0B)
                            !settings.isShiftReadingEnabled -> Color(0xFFEF4444)
                            else -> Color(0xFF10B981)
                        }
                    )
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = when {
                    !isAccessibilityActive -> "Permissão Pendente"
                    !settings.isShiftReadingEnabled -> "Leitor Pausado"
                    else -> "Leitor Ativo"
                },
                color = when {
                    !isAccessibilityActive -> Color(0xFFF59E0B)
                    !settings.isShiftReadingEnabled -> Color(0xFFEF4444)
                    else -> Color(0xFF10B981)
                },
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold
            )
        }

        val bgColor = when (analysis?.verdict) {
            RideVerdict.APPROVED -> Color(0xFF059669)
            RideVerdict.WARNING -> Color(0xFFD97706)
            RideVerdict.REJECTED -> Color(0xFFDC2626)
            null -> Color(0xFF141C2B)
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(158.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(bgColor)
                .border(
                    width = 2.dp,
                    color = if (isAccessibilityActive && settings.isShiftReadingEnabled) Color(0xFF10B981).copy(alpha = 0.65f) else Color.White.copy(alpha = 0.14f),
                    shape = RoundedCornerShape(18.dp)
                )
                .padding(14.dp),
            contentAlignment = Alignment.Center
        ) {
            if (analysis != null) {
                val shownKm = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.NET) analysis.netPerKm else analysis.grossPerKm
                val shownHour = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.NET) analysis.netPerHour else analysis.grossPerHour

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

                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxSize()
                ) {
                    Text(
                        text = "${analysis.offer.appSource} • ${analysis.verdict.rawValue} • LUCRO ${formatBRL(analysis.netProfitBRL)}",
                        color = Color.White,
                        fontWeight = FontWeight.Black,
                        fontSize = 13.5.sp,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color.Black.copy(alpha = 0.30f))
                            .padding(horizontal = 12.dp, vertical = 4.dp)
                    )

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "${formatBRL(shownKm)}/km",
                            color = Color.White,
                            fontWeight = FontWeight.Black,
                            fontSize = 28.sp
                        )
                        Text(
                            text = String.format(Locale("pt", "BR"), "R$ %.0f/h", shownHour),
                            color = Color.White,
                            fontWeight = FontWeight.Black,
                            fontSize = 28.sp
                        )
                    }

                    Text(
                        text = String.format(
                            Locale("pt", "BR"),
                            "Tarifa %s • %s (%d min) • Comb. -%s",
                            formatBRL(analysis.offer.fareBRL),
                            distDetail,
                            analysis.offer.totalMinutes,
                            formatBRL(analysis.fuelCostBRL)
                        ),
                        color = Color.White.copy(alpha = 0.96f),
                        fontWeight = FontWeight.Bold,
                        fontSize = 11.5.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            } else if (!settings.isShiftReadingEnabled) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = "⏸️ LEITOR DESLIGADO (FORA DE TURNO)",
                        color = Color(0xFFF87171),
                        fontWeight = FontWeight.Black,
                        fontSize = 16.5.sp,
                        textAlign = TextAlign.Center
                    )
                    Text(
                        text = "O leitor está pausado e não lê nenhuma tela agora.\nToque no botão verde abaixo quando for trabalhar!",
                        color = Color(0xFF9CA3AF),
                        fontSize = 12.5.sp,
                        textAlign = TextAlign.Center
                    )
                }
            } else {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Text(
                        text = "🟢 UBER & 99 PROFIT ATIVO",
                        color = Color.White,
                        fontWeight = FontWeight.Black,
                        fontSize = 19.sp
                    )
                    Text(
                        text = "Monitorando Uber e 99 • Meta ${formatBRL(settings.targetBRLPerKm)}/km e R$ ${settings.targetBRLPerHour.toInt()}/h",
                        color = Color(0xFF10B981),
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.5.sp,
                        textAlign = TextAlign.Center
                    )
                    Text(
                        text = "A Pílula Flutuante fica discreta no mapa e se abre sozinha quando tocar corrida!",
                        color = Color(0xFF9CA3AF),
                        fontSize = 11.5.sp,
                        textAlign = TextAlign.Center
                    )
                }
            }
        }
    }
}

@Composable
private fun QuickAcceptLastRideBar(
    item: RideAnalysis,
    alreadyAccepted: Boolean,
    onAccept: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0xFF161E2E))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = "Última Oferta: [${item.offer.appSource}] ${formatBRL(item.offer.fareBRL)}",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp
            )
            Text(
                text = String.format(
                    Locale("pt", "BR"),
                    "%.1f km (%d min) • Lucro Livre %s",
                    item.offer.totalDistanceKm,
                    item.offer.totalMinutes,
                    formatBRL(item.netProfitBRL)
                ),
                color = Color(0xFF9CA3AF),
                fontSize = 11.5.sp
            )
        }

        Button(
            onClick = onAccept,
            enabled = !alreadyAccepted,
            colors = ButtonDefaults.buttonColors(
                containerColor = Color(0xFF10B981),
                disabledContainerColor = Color(0xFF10B981).copy(alpha = 0.2f)
            ),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
            shape = CircleShape
        ) {
            Icon(
                imageVector = if (alreadyAccepted) Icons.Default.CheckCircle else Icons.Default.AddCircle,
                contentDescription = null,
                tint = if (alreadyAccepted) Color(0xFF10B981) else Color.White,
                modifier = Modifier.size(16.dp)
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = if (alreadyAccepted) "Já nos Ganhos" else "Aceitei Corrida",
                color = if (alreadyAccepted) Color(0xFF10B981) else Color.White,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

@Composable
private fun ShiftControlsSection(
    settings: DriverSettings,
    isAccessibilityActive: Boolean,
    isOverlayActive: Boolean,
    onOpenAccessibilitySettings: () -> Unit,
    onToggleOrRequestOverlay: () -> Unit,
    onOpenAppDetailsSettings: () -> Unit,
    onNavigateToCustomize: () -> Unit
) {
    val context = LocalContext.current

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // CHAVE GERAL DE 1 TOQUE: LIGAR / DESLIGAR LEITOR (INICIAR / PAUSAR TURNO)
        Button(
            onClick = { AppStateRepository.toggleShiftReading(context) },
            modifier = Modifier
                .fillMaxWidth()
                .height(62.dp),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (settings.isShiftReadingEnabled) Color(0xFFDC2626) else Color(0xFF059669)
            )
        ) {
            Icon(
                imageVector = if (settings.isShiftReadingEnabled) Icons.Default.PauseCircleFilled else Icons.Default.PlayCircleFilled,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(28.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(horizontalAlignment = Alignment.Start) {
                Text(
                    text = if (settings.isShiftReadingEnabled) "DESLIGAR / PAUSAR LEITOR" else "LIGAR LEITOR (INICIAR TURNO)",
                    color = Color.White,
                    fontWeight = FontWeight.Black,
                    fontSize = 14.5.sp
                )
                Text(
                    text = if (settings.isShiftReadingEnabled) {
                        "Leitor ATIVO • Toque aqui quando parar de trabalhar"
                    } else {
                        "Leitor PAUSADO • Toque aqui para monitorar Uber e 99"
                    },
                    color = Color.White.copy(alpha = 0.92f),
                    fontSize = 11.sp
                )
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            // Botão 1: Acessibilidade (Permissão do Sistema)
            Button(
                onClick = onOpenAccessibilitySettings,
                modifier = Modifier
                    .weight(1f)
                    .height(56.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (isAccessibilityActive) Color(0xFF1F2937) else Color(0xFF2563EB)
                ),
                contentPadding = PaddingValues(horizontal = 10.dp)
            ) {
                Icon(
                    imageVector = if (isAccessibilityActive) Icons.Default.VerifiedUser else Icons.Default.Visibility,
                    contentDescription = null,
                    tint = if (isAccessibilityActive) Color(0xFF10B981) else Color.White
                )
                Spacer(modifier = Modifier.width(8.dp))
                Column(horizontalAlignment = Alignment.Start) {
                    Text(
                        text = if (isAccessibilityActive) "Permissão OK" else "1. Autorizar App",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.5.sp
                    )
                    Text(
                        text = if (isAccessibilityActive) "Acessibilidade ativa" else "Fazer 1 única vez",
                        color = Color.White.copy(alpha = 0.78f),
                        fontSize = 10.sp
                    )
                }
            }

            // Botão 2: Janela Flutuante ou Modo Notificação
            if (settings.visualAlertMode != VisualAlertMode.NOTIFICATION) {
                Button(
                    onClick = onToggleOrRequestOverlay,
                    modifier = Modifier
                        .weight(1f)
                        .height(56.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (isOverlayActive) Color(0xFFD97706) else Color(0xFF059669)
                    ),
                    contentPadding = PaddingValues(horizontal = 10.dp)
                ) {
                    Icon(
                        imageVector = if (isOverlayActive) Icons.Default.CloseFullscreen else Icons.Default.PictureInPictureAlt,
                        contentDescription = null,
                        tint = Color.White
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Column(horizontalAlignment = Alignment.Start) {
                        Text(
                            text = if (isOverlayActive) "Pílula Ativa" else "2. Abrir Pílula",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.5.sp
                        )
                        Text(
                            text = if (isOverlayActive) "Toque p/ ocultar" else "Flutuante no mapa",
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 10.sp
                        )
                    }
                }
            } else {
                Button(
                    onClick = onNavigateToCustomize,
                    modifier = Modifier
                        .weight(1f)
                        .height(56.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4F46E5)),
                    contentPadding = PaddingValues(horizontal = 10.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.NotificationsActive,
                        contentDescription = null,
                        tint = Color.White
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Column(horizontalAlignment = Alignment.Start) {
                        Text(
                            text = "Só Notificação",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.5.sp
                        )
                        Text(
                            text = "Toque p/ mudar",
                            color = Color.White.copy(alpha = 0.85f),
                            fontSize = 10.sp
                        )
                    }
                }
            }
        }

        if (!isAccessibilityActive) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFFF59E0B).copy(alpha = 0.14f))
                    .border(1.dp, Color(0xFFF59E0B).copy(alpha = 0.35f), RoundedCornerShape(12.dp))
                    .clickable { onOpenAppDetailsSettings() }
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Default.LockOpen,
                    contentDescription = null,
                    tint = Color(0xFFF59E0B),
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Apareceu \"Acesso negado / Permissão restrita\"?",
                        color = Color(0xFFF59E0B),
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.sp
                    )
                    Text(
                        text = "1. Toque aqui → 2. Toque nos 3 pontinhos (⋮) no canto superior direito → 3. \"Permitir configurações restritas\".",
                        color = Color.White.copy(alpha = 0.92f),
                        fontSize = 11.sp
                    )
                }
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF161E2E))
                .padding(horizontal = 14.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Default.VolumeUp,
                contentDescription = null,
                tint = if (settings.voiceAlertsEnabled) Color(0xFF10B981) else Color(0xFF9CA3AF),
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = "Aviso por Voz em Português",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 12.5.sp,
                modifier = Modifier.weight(1f)
            )
            Text(
                text = if (settings.voiceAlertsEnabled) "Ligada" else "Mudo",
                color = if (settings.voiceAlertsEnabled) Color(0xFF10B981) else Color(0xFF9CA3AF),
                fontWeight = FontWeight.Bold,
                fontSize = 12.sp
            )
            Spacer(modifier = Modifier.width(8.dp))
            Switch(
                checked = settings.voiceAlertsEnabled,
                onCheckedChange = { enabled ->
                    AppStateRepository.updateSettings(context) { it.copy(voiceAlertsEnabled = enabled) }
                }
            )
        }
    }
}

@Composable
private fun ShiftStatsSection(
    history: List<RideAnalysis>,
    acceptedCount: Int,
    onOpenEarnings: () -> Unit
) {
    val approvedCount = history.count { it.verdict == RideVerdict.APPROVED }
    val warningCount = history.count { it.verdict == RideVerdict.WARNING }
    val rejectedCount = history.count { it.verdict == RideVerdict.REJECTED }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Resumo das Ofertas Lidas Hoje",
                color = Color(0xFF9CA3AF),
                fontWeight = FontWeight.Bold,
                fontSize = 12.sp,
                modifier = Modifier.weight(1f)
            )
            Text(
                text = "Ver Ganhos ($acceptedCount aceitas) →",
                color = Color(0xFF10B981),
                fontWeight = FontWeight.Bold,
                fontSize = 12.sp,
                modifier = Modifier.clickable { onOpenEarnings() }
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            StatBadge(title = "Boas", value = "$approvedCount", color = Color(0xFF10B981), modifier = Modifier.weight(1f))
            StatBadge(title = "Atenção", value = "$warningCount", color = Color(0xFFF59E0B), modifier = Modifier.weight(1f))
            StatBadge(title = "Recusadas", value = "$rejectedCount", color = Color(0xFFEF4444), modifier = Modifier.weight(1f))
            StatBadge(title = "Aceitas", value = "$acceptedCount", color = Color(0xFF3B82F6), modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatBadge(
    title: String,
    value: String,
    color: Color,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xFF161E2E))
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = value,
            color = color,
            fontWeight = FontWeight.Bold,
            fontSize = 15.sp
        )
        Text(
            text = title,
            color = Color(0xFF9CA3AF),
            fontSize = 11.sp
        )
    }
}

@Composable
private fun TestSimulationSection(
    onSimulateOffer: (RideOfferPayload) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Simular Corrida Agora (Testar Voz + Pílula Flutuante)",
            color = Color(0xFF9CA3AF),
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Button(
                onClick = {
                    onSimulateOffer(
                        RideOfferPayload(
                            appSource = "UBER",
                            fareBRL = 24.50,
                            pickupDistanceKm = 0.8,
                            tripDistanceKm = 7.2,
                            totalDistanceKm = 8.0,
                            pickupMinutes = 3,
                            tripMinutes = 14,
                            totalMinutes = 17,
                            rawRecognizedText = "UberX Exclusivo\nR$ 24,50\n3 min (0.8 km)\n14 minutos (7.2 km)\nAceitar",
                            timestamp = System.currentTimeMillis() / 1000.0
                        )
                    )
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF059669)),
                contentPadding = PaddingValues(vertical = 10.dp, horizontal = 6.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text("🟢 Boa", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }

            Button(
                onClick = {
                    onSimulateOffer(
                        RideOfferPayload(
                            appSource = "99",
                            fareBRL = 16.20,
                            pickupDistanceKm = 1.2,
                            tripDistanceKm = 6.8,
                            totalDistanceKm = 8.0,
                            pickupMinutes = 4,
                            tripMinutes = 16,
                            totalMinutes = 20,
                            rawRecognizedText = "99Pop\nR$ 16,20\n4 min (1.2 km)\n16 min (6.8 km)\nAceitar",
                            timestamp = System.currentTimeMillis() / 1000.0
                        )
                    )
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFD97706)),
                contentPadding = PaddingValues(vertical = 10.dp, horizontal = 6.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text("🟡 Média", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }

            Button(
                onClick = {
                    onSimulateOffer(
                        RideOfferPayload(
                            appSource = "99",
                            fareBRL = 10.30,
                            pickupDistanceKm = 1.8,
                            tripDistanceKm = 6.2,
                            totalDistanceKm = 8.0,
                            pickupMinutes = 5,
                            tripMinutes = 18,
                            totalMinutes = 23,
                            rawRecognizedText = "99Pop\nR$ 10,30\n5 min (1.8 km)\n18 min (6.2 km)\nAceitar",
                            timestamp = System.currentTimeMillis() / 1000.0
                        )
                    )
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626)),
                contentPadding = PaddingValues(vertical = 10.dp, horizontal = 6.dp),
                shape = RoundedCornerShape(12.dp)
            ) {
                Text("🔴 Ruim", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

// MARK: - ABA 2: GANHOS DO TURNO (CORRIDAS ACEITAS)
@Composable
private fun EarningsTabView(
    settings: DriverSettings,
    latestAnalysis: RideAnalysis?,
    lastSeenAnalysis: RideAnalysis?,
    acceptedRides: List<RideAnalysis>,
    onOpenManualRideDialog: () -> Unit
) {
    val context = LocalContext.current

    val totalGrossBRL = acceptedRides.sumOf { it.offer.fareBRL }
    val totalPickupKm = acceptedRides.sumOf { it.offer.pickupDistanceKm }
    val totalTripKm = acceptedRides.sumOf { it.offer.tripDistanceKm }
    val totalKm = acceptedRides.sumOf { it.offer.totalDistanceKm }
    val totalMinutes = acceptedRides.sumOf { it.offer.totalMinutes }
    val totalLiters = totalKm / max(settings.carConsumptionKmPerLiter, 1.0)
    val totalFuelCostBRL = totalLiters * settings.fuelPriceBRLPerLiter
    val totalNetProfitBRL = totalGrossBRL - totalFuelCostBRL - settings.extraDailyExpenseBRL

    val avgGrossPerKm = if (totalKm > 0) totalGrossBRL / totalKm else 0.0
    val avgNetPerKm = if (totalKm > 0) totalNetProfitBRL / totalKm else 0.0
    val avgGrossPerHour = if (totalMinutes > 0) (totalGrossBRL / totalMinutes.toDouble()) * 60.0 else 0.0
    val avgNetPerHour = if (totalMinutes > 0) (totalNetProfitBRL / totalMinutes.toDouble()) * 60.0 else 0.0

    val uberCount = acceptedRides.count { it.offer.appSource == "UBER" }
    val ninenineCount = acceptedRides.count { it.offer.appSource == "99" }
    val goalProgress = if (settings.dailyNetGoalBRL > 0) {
        (totalNetProfitBRL / settings.dailyNetGoalBRL).toFloat().coerceIn(0f, 1f)
    } else 0f

    // 1. Card Principal Verde em Degradê: Lucro Livre no Bolso
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(Color(0xFF059669), Color(0xFF065F46))
                )
            )
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Default.AccountBalanceWallet,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = "GANHOS DO TURNO",
                color = Color.White.copy(alpha = 0.92f),
                fontWeight = FontWeight.Black,
                fontSize = 12.sp,
                modifier = Modifier.weight(1f)
            )
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.22f))
                    .padding(horizontal = 10.dp, vertical = 3.dp)
            ) {
                Text(
                    text = "${acceptedRides.size} Corridas Aceitas",
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp
                )
            }
        }

        Column(
            modifier = Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "LUCRO LIVRE NO BOLSO",
                color = Color.White.copy(alpha = 0.85f),
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp
            )
            Text(
                text = formatBRL(totalNetProfitBRL),
                color = Color.White,
                fontWeight = FontWeight.Black,
                fontSize = 35.sp
            )
        }

        HorizontalDivider(color = Color.White.copy(alpha = 0.25f))

        Row(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.weight(1f),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text("Ganho Bruto", color = Color.White.copy(alpha = 0.8f), fontSize = 11.sp)
                Text(formatBRL(totalGrossBRL), color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            }
            Column(
                modifier = Modifier.weight(1f),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = String.format(Locale("pt", "BR"), "Gasolina (%.1f L)", totalLiters),
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 11.sp
                )
                Text(
                    text = "-${formatBRL(totalFuelCostBRL)}",
                    color = Color(0xFFFFD966),
                    fontWeight = FontWeight.Bold,
                    fontSize = 14.sp
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text("Gasto Extra", color = Color.White.copy(alpha = 0.8f), fontSize = 11.sp)
                Text(
                    text = "-${formatBRL(settings.extraDailyExpenseBRL)}",
                    color = Color(0xFFFFD966),
                    fontWeight = FontWeight.Bold,
                    fontSize = 14.sp
                )
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "Meta Diária Livre: ${formatBRL(settings.dailyNetGoalBRL)}",
                    color = Color.White.copy(alpha = 0.9f),
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = "${(goalProgress * 100).roundToInt()}% concluída",
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp
                )
            }
            LinearProgressIndicator(
                progress = { goalProgress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(8.dp)
                    .clip(CircleShape),
                color = Color.White,
                trackColor = Color.Black.copy(alpha = 0.28f)
            )
        }
    }

    // 2. Grade de Quilometragem, Tempo e Médias Reais
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Resumo de KM Rodados, Tempo e Médias",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 13.5.sp,
                modifier = Modifier.weight(1f)
            )
            if (acceptedRides.isNotEmpty()) {
                Text(
                    text = "📤 Compartilhar",
                    color = Color(0xFF60A5FA),
                    fontWeight = FontWeight.Bold,
                    fontSize = 12.sp,
                    modifier = Modifier.clickable {
                        shareShiftReport(
                            context = context,
                            ridesCount = acceptedRides.size,
                            uberCount = uberCount,
                            ninenineCount = ninenineCount,
                            grossBRL = totalGrossBRL,
                            fuelBRL = totalFuelCostBRL,
                            extraBRL = settings.extraDailyExpenseBRL,
                            netBRL = totalNetProfitBRL,
                            totalKm = totalKm,
                            totalMinutes = totalMinutes,
                            avgGrossKm = avgGrossPerKm,
                            avgNetKm = avgNetPerKm
                        )
                    }
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            EarningsMetricBox(
                icon = Icons.Default.Route,
                title = "KM Total Rodado",
                mainValue = String.format(Locale("pt", "BR"), "%.1f km", totalKm),
                subValue = String.format(Locale("pt", "BR"), "Busca: %.1f • Viagem: %.1f", totalPickupKm, totalTripKm),
                color = Color(0xFF3B82F6),
                modifier = Modifier.weight(1f)
            )
            EarningsMetricBox(
                icon = Icons.Default.Schedule,
                title = "Tempo em Corridas",
                mainValue = formatDuration(totalMinutes),
                subValue = "Uber: $uberCount • 99: $ninenineCount",
                color = Color(0xFFA855F7),
                modifier = Modifier.weight(1f)
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            EarningsMetricBox(
                icon = Icons.Default.Speed,
                title = "Média por KM",
                mainValue = "${formatBRL(avgGrossPerKm)}/km",
                subValue = "Livre: ${formatBRL(avgNetPerKm)}/km",
                color = Color(0xFF10B981),
                modifier = Modifier.weight(1f)
            )
            EarningsMetricBox(
                icon = Icons.Default.HourglassBottom,
                title = "Média por Hora",
                mainValue = String.format(Locale("pt", "BR"), "R$ %.0f/h", avgGrossPerHour),
                subValue = String.format(Locale("pt", "BR"), "Livre: R$ %.0f/h", avgNetPerHour),
                color = Color(0xFFF59E0B),
                modifier = Modifier.weight(1f)
            )
        }
    }

    // 3. Ações Rápidas, Detecção Automática, Meta Diária e Gasto Extra
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = onOpenManualRideDialog,
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2563EB)),
                shape = RoundedCornerShape(12.dp)
            ) {
                Icon(Icons.Default.AddCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(modifier = Modifier.width(6.dp))
                Text("Lançar Corrida Manual", fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }

            val lastCandidate = latestAnalysis ?: lastSeenAnalysis
            if (lastCandidate != null && !AppStateRepository.isRideAlreadyAccepted(lastCandidate)) {
                Button(
                    onClick = { AppStateRepository.acceptRide(context, lastCandidate) },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF059669)),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Icon(Icons.Default.CheckCircle, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = "Aceitei Última (${formatBRL(lastCandidate.offer.fareBRL)})",
                        fontSize = 11.5.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1
                    )
                }
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Detectar Corrida Aceita Automaticamente",
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.5.sp
                )
                Text(
                    text = "Salva nos Ganhos quando você toca em 'Aceitar' ou inicia a viagem na Uber/99.",
                    color = Color(0xFF9CA3AF),
                    fontSize = 11.5.sp
                )
            }
            Switch(
                checked = settings.autoDetectAcceptedRides,
                onCheckedChange = { enabled ->
                    AppStateRepository.updateSettings(context) { it.copy(autoDetectAcceptedRides = enabled) }
                }
            )
        }

        HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

        AdjustableMetricSlider(
            title = "Meta Diária de Lucro Livre",
            formattedValue = formatBRL(settings.dailyNetGoalBRL),
            valueColor = Color(0xFF10B981),
            value = settings.dailyNetGoalBRL.toFloat(),
            valueRange = 50f..600f,
            onValueChange = { v ->
                val stepped = (v / 10f).roundToInt() * 10.0
                AppStateRepository.updateSettings(context) { it.copy(dailyNetGoalBRL = stepped) }
            },
            onStepMinus = {
                val next = (settings.dailyNetGoalBRL - 10.0).coerceAtLeast(50.0)
                AppStateRepository.updateSettings(context) { it.copy(dailyNetGoalBRL = next) }
            },
            onStepPlus = {
                val next = (settings.dailyNetGoalBRL + 10.0).coerceAtMost(600.0)
                AppStateRepository.updateSettings(context) { it.copy(dailyNetGoalBRL = next) }
            }
        )

        AdjustableMetricSlider(
            title = "Gasto Extra Hoje (Lanche / Aluguel / Lavagem)",
            formattedValue = formatBRL(settings.extraDailyExpenseBRL),
            valueColor = Color(0xFFF59E0B),
            value = settings.extraDailyExpenseBRL.toFloat(),
            valueRange = 0f..250f,
            onValueChange = { v ->
                val stepped = (v / 5f).roundToInt() * 5.0
                AppStateRepository.updateSettings(context) { it.copy(extraDailyExpenseBRL = stepped) }
            },
            onStepMinus = {
                val next = (settings.extraDailyExpenseBRL - 5.0).coerceAtLeast(0.0)
                AppStateRepository.updateSettings(context) { it.copy(extraDailyExpenseBRL = next) }
            },
            onStepPlus = {
                val next = (settings.extraDailyExpenseBRL + 5.0).coerceAtMost(250.0)
                AppStateRepository.updateSettings(context) { it.copy(extraDailyExpenseBRL = next) }
            }
        )
    }

    // 4. Lista de Corridas Aceitas no Turno
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Corridas Aceitas (${acceptedRides.size})",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp,
                modifier = Modifier.weight(1f)
            )
            if (acceptedRides.isNotEmpty()) {
                Text(
                    text = "Zerar Turno",
                    color = Color(0xFFEF4444),
                    fontWeight = FontWeight.Bold,
                    fontSize = 12.sp,
                    modifier = Modifier.clickable {
                        AppStateRepository.clearShiftEarnings(context)
                    }
                )
            }
        }

        if (acceptedRides.isEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color(0xFF161E2E))
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.DirectionsCar,
                    contentDescription = null,
                    tint = Color(0xFF9CA3AF),
                    modifier = Modifier.size(34.dp)
                )
                Text(
                    text = "Nenhuma corrida aceita registrada ainda.",
                    color = Color(0xFF9CA3AF),
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.5.sp
                )
                Text(
                    text = "Quando você aceitar uma corrida na Uber ou 99, ela aparecerá aqui automaticamente (ou toque em 'Aceitei' na Janela Flutuante / Painel).",
                    color = Color(0xFF6B7280),
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center
                )
            }
        } else {
            acceptedRides.forEach { item ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color(0xFF161E2E))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            val is99 = item.offer.appSource == "99"
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(5.dp))
                                    .background(
                                        if (is99) Color(0xFFF59E0B).copy(alpha = 0.2f)
                                        else Color(0xFF3B82F6).copy(alpha = 0.2f)
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp)
                            ) {
                                Text(
                                    text = item.offer.appSource,
                                    color = if (is99) Color(0xFFF59E0B) else Color(0xFF60A5FA),
                                    fontWeight = FontWeight.Black,
                                    fontSize = 10.sp
                                )
                            }
                            Text(
                                text = formatTime(item.offer.timestamp),
                                color = Color(0xFF9CA3AF),
                                fontSize = 11.sp
                            )
                            Text(
                                text = String.format(
                                    Locale("pt", "BR"),
                                    "• %.1f km • %d min",
                                    item.offer.totalDistanceKm,
                                    item.offer.totalMinutes
                                ),
                                color = Color.White,
                                fontWeight = FontWeight.Bold,
                                fontSize = 12.sp
                            )
                        }
                        Text(
                            text = "Bruto: ${formatBRL(item.offer.fareBRL)}  •  Gasolina: -${formatBRL(item.fuelCostBRL)}",
                            color = Color(0xFF9CA3AF),
                            fontSize = 11.5.sp
                        )
                    }

                    Column(horizontalAlignment = Alignment.End) {
                        Text(
                            text = "+${formatBRL(item.netProfitBRL)}",
                            color = Color(0xFF10B981),
                            fontWeight = FontWeight.Black,
                            fontSize = 14.sp
                        )
                        Text(
                            text = "${formatBRL(item.grossPerKm)}/km",
                            color = Color(0xFF9CA3AF),
                            fontWeight = FontWeight.Bold,
                            fontSize = 11.sp
                        )
                    }

                    Spacer(modifier = Modifier.width(8.dp))

                    IconButton(
                        onClick = { AppStateRepository.removeAcceptedRide(context, item) },
                        modifier = Modifier
                            .size(32.dp)
                            .clip(CircleShape)
                            .background(Color(0xFFEF4444).copy(alpha = 0.14f))
                    ) {
                        Icon(
                            imageVector = Icons.Default.Delete,
                            contentDescription = "Remover",
                            tint = Color(0xFFEF4444),
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EarningsMetricBox(
    icon: ImageVector,
    title: String,
    mainValue: String,
    subValue: String,
    color: Color,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0xFF222D42))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
            Spacer(modifier = Modifier.width(4.dp))
            Text(title, color = Color(0xFF9CA3AF), fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Text(mainValue, color = Color.White, fontWeight = FontWeight.Black, fontSize = 16.sp)
        Text(subValue, color = Color(0xFF9CA3AF), fontSize = 10.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: - ABA 3: METAS & CARRO (COM BOTÕES '-' E '+' DE AJUSTE FINO)
@Composable
private fun GoalsAndVehicleTabView(settings: DriverSettings) {
    val context = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("Suas Metas Mínimas", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)

        AdjustableMetricSlider(
            title = "Meta Mínima por KM",
            formattedValue = "${formatBRL(settings.targetBRLPerKm)}/km",
            valueColor = Color(0xFF10B981),
            value = settings.targetBRLPerKm.toFloat(),
            valueRange = 1.00f..5.00f,
            onValueChange = { v ->
                val stepped = (v * 20f).roundToInt() / 20.0
                AppStateRepository.updateSettings(context) { it.copy(targetBRLPerKm = stepped) }
            },
            onStepMinus = {
                val next = ((settings.targetBRLPerKm - 0.05) * 20.0).roundToInt() / 20.0
                AppStateRepository.updateSettings(context) { it.copy(targetBRLPerKm = next.coerceAtLeast(1.0)) }
            },
            onStepPlus = {
                val next = ((settings.targetBRLPerKm + 0.05) * 20.0).roundToInt() / 20.0
                AppStateRepository.updateSettings(context) { it.copy(targetBRLPerKm = next.coerceAtMost(5.0)) }
            }
        )

        HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

        AdjustableMetricSlider(
            title = "Meta Mínima por Hora",
            formattedValue = String.format(Locale("pt", "BR"), "R$ %.0f/h", settings.targetBRLPerHour),
            valueColor = Color(0xFF10B981),
            value = settings.targetBRLPerHour.toFloat(),
            valueRange = 20f..120f,
            onValueChange = { v ->
                val stepped = (v / 2f).roundToInt() * 2.0
                AppStateRepository.updateSettings(context) { it.copy(targetBRLPerHour = stepped) }
            },
            onStepMinus = {
                val next = (settings.targetBRLPerHour - 2.0).coerceAtLeast(20.0)
                AppStateRepository.updateSettings(context) { it.copy(targetBRLPerHour = next) }
            },
            onStepPlus = {
                val next = (settings.targetBRLPerHour + 2.0).coerceAtMost(120.0)
                AppStateRepository.updateSettings(context) { it.copy(targetBRLPerHour = next) }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Consumo & Combustível",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp,
                modifier = Modifier.weight(1f)
            )
            Box(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Color(0xFFF59E0B).copy(alpha = 0.18f))
                    .padding(horizontal = 10.dp, vertical = 4.dp)
            ) {
                Text(
                    text = "Custo: ${formatBRL(settings.fuelCostPerKm)}/km",
                    color = Color(0xFFF59E0B),
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.5.sp
                )
            }
        }

        AdjustableMetricSlider(
            title = "Consumo do Seu Carro",
            formattedValue = String.format(Locale("pt", "BR"), "%.1f km/L", settings.carConsumptionKmPerLiter),
            valueColor = Color(0xFF60A5FA),
            value = settings.carConsumptionKmPerLiter.toFloat(),
            valueRange = 5.0f..22.0f,
            onValueChange = { v ->
                val stepped = (v * 2f).roundToInt() / 2.0
                AppStateRepository.updateSettings(context) { it.copy(carConsumptionKmPerLiter = stepped) }
            },
            onStepMinus = {
                val next = ((settings.carConsumptionKmPerLiter - 0.5) * 2.0).roundToInt() / 2.0
                AppStateRepository.updateSettings(context) { it.copy(carConsumptionKmPerLiter = next.coerceAtLeast(5.0)) }
            },
            onStepPlus = {
                val next = ((settings.carConsumptionKmPerLiter + 0.5) * 2.0).roundToInt() / 2.0
                AppStateRepository.updateSettings(context) { it.copy(carConsumptionKmPerLiter = next.coerceAtMost(22.0)) }
            }
        )

        HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

        AdjustableMetricSlider(
            title = "Preço do Litro (Gasolina/Etanol)",
            formattedValue = "${formatBRL(settings.fuelPriceBRLPerLiter)}/L",
            valueColor = Color(0xFFF59E0B),
            value = settings.fuelPriceBRLPerLiter.toFloat(),
            valueRange = 3.00f..9.00f,
            onValueChange = { v ->
                val stepped = (v * 20f).roundToInt() / 20.0
                AppStateRepository.updateSettings(context) { it.copy(fuelPriceBRLPerLiter = stepped) }
            },
            onStepMinus = {
                val next = ((settings.fuelPriceBRLPerLiter - 0.05) * 20.0).roundToInt() / 20.0
                AppStateRepository.updateSettings(context) { it.copy(fuelPriceBRLPerLiter = next.coerceAtLeast(3.0)) }
            },
            onStepPlus = {
                val next = ((settings.fuelPriceBRLPerLiter + 0.05) * 20.0).roundToInt() / 20.0
                AppStateRepository.updateSettings(context) { it.copy(fuelPriceBRLPerLiter = next.coerceAtMost(9.0)) }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Avaliar Meta pelo Lucro Líquido",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp,
                modifier = Modifier.weight(1f)
            )
            Switch(
                checked = settings.evaluateUsingNetProfit,
                onCheckedChange = { enabled ->
                    AppStateRepository.updateSettings(context) { it.copy(evaluateUsingNetProfit = enabled) }
                }
            )
        }

        val requiredGross = settings.targetBRLPerKm + settings.fuelCostPerKm
        val netLeftover = max(settings.targetBRLPerKm - settings.fuelCostPerKm, 0.0)

        if (settings.evaluateUsingNetProfit) {
            Text(
                text = "MODO RIGOROSO ATIVO: Como seu carro gasta ${formatBRL(settings.fuelCostPerKm)}/km de combustível, para sobrar ${formatBRL(settings.targetBRLPerKm)}/km livres no bolso, o app só dará VERDE se a corrida na tela da Uber/99 pagar pelo menos ${formatBRL(requiredGross)}/km bruto!",
                color = Color(0xFFF59E0B),
                fontSize = 12.sp
            )
        } else {
            Text(
                text = "MODO PADRÃO ATIVO: O app dará VERDE sempre que a corrida na tela da Uber/99 pagar a partir de ${formatBRL(settings.targetBRLPerKm)}/km bruto (descontando ${formatBRL(settings.fuelCostPerKm)}/km de gasolina, sobram ${formatBRL(netLeftover)}/km livres no seu bolso).",
                color = Color(0xFF9CA3AF),
                fontSize = 12.sp
            )
        }
    }
}

@Composable
private fun AdjustableMetricSlider(
    title: String,
    formattedValue: String,
    valueColor: Color,
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit,
    onStepMinus: () -> Unit,
    onStepPlus: () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = title,
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f)
            )
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF222D42))
                    .clickable { onStepMinus() },
                contentAlignment = Alignment.Center
            ) {
                Text("-", color = Color.White, fontWeight = FontWeight.Black, fontSize = 16.sp)
            }
            Text(
                text = formattedValue,
                color = valueColor,
                fontWeight = FontWeight.Black,
                fontSize = 13.5.sp,
                modifier = Modifier.padding(horizontal = 10.dp)
            )
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(Color(0xFF222D42))
                    .clickable { onStepPlus() },
                contentAlignment = Alignment.Center
            ) {
                Text("+", color = Color.White, fontWeight = FontWeight.Black, fontSize = 16.sp)
            }
        }
        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange
        )
    }
}

// MARK: - ABA 4: PERSONALIZAÇÃO DE ALERTAS E VOZ
@Composable
private fun CustomizationTabView(settings: DriverSettings) {
    val context = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text("Como Exibir o Alerta na Tela", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            VisualAlertMode.entries.forEach { mode ->
                val selected = settings.visualAlertMode == mode
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (selected) Color(0xFF2563EB) else Color(0xFF222D42))
                        .clickable {
                            AppStateRepository.updateSettings(context) { it.copy(visualAlertMode = mode) }
                        }
                        .padding(vertical = 10.dp, horizontal = 4.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = mode.title,
                        color = Color.White,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center
                    )
                }
            }
        }

        Text(
            text = when (settings.visualAlertMode) {
                VisualAlertMode.NOTIFICATION -> "• Só Notificação: Não abre janela flutuante. Mostra apenas um Banner rápido no topo quando a corrida toca."
                VisualAlertMode.PIP -> "• Só Janela Flutuante: Mantém a Pílula Compacta discreta em cima do mapa, que se expande sozinha quando toca corrida."
                VisualAlertMode.BOTH -> "• Ambos: Mantém a Pílula Flutuante inteligente e também dispara o Banner no topo."
            },
            color = Color(0xFF9CA3AF),
            fontSize = 12.sp
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text("Número Principal em Destaque", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            PrimaryMetricDisplay.entries.forEach { mode ->
                val selected = settings.primaryMetricDisplay == mode
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(10.dp))
                        .background(if (selected) Color(0xFF2563EB) else Color(0xFF222D42))
                        .clickable {
                            AppStateRepository.updateSettings(context) { it.copy(primaryMetricDisplay = mode) }
                        }
                        .padding(vertical = 10.dp, horizontal = 6.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = mode.title,
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center
                    )
                }
            }
        }

        Text(
            text = if (settings.primaryMetricDisplay == PrimaryMetricDisplay.GROSS) {
                "Mostra o R$/km Bruto (igual ao da tela da Uber/99) em letras grandes e o Lucro Líquido no cabeçalho."
            } else {
                "Mostra já o R$/km Líquido (descontando a gasolina) diretamente nas letras gigantes e na voz."
            },
            color = Color(0xFF9CA3AF),
            fontSize = 12.sp
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color(0xFF161E2E))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "Ativar Voz Automática",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp,
                modifier = Modifier.weight(1f)
            )
            Switch(
                checked = settings.voiceAlertsEnabled,
                onCheckedChange = { enabled ->
                    AppStateRepository.updateSettings(context) { it.copy(voiceAlertsEnabled = enabled) }
                }
            )
        }

        if (settings.voiceAlertsEnabled) {
            HorizontalDivider(color = Color.White.copy(alpha = 0.1f))
            Text("Estilo da Fala:", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)

            VoiceSpeechStyle.entries.forEach { style ->
                val isSelected = settings.voiceSpeechStyle == style
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(
                            if (isSelected) Color(0xFF3B82F6).copy(alpha = 0.16f)
                            else Color(0xFF222D42)
                        )
                        .clickable {
                            AppStateRepository.updateSettings(context) { it.copy(voiceSpeechStyle = style) }
                        }
                        .padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = if (isSelected) Icons.Default.RadioButtonChecked else Icons.Default.RadioButtonUnchecked,
                        contentDescription = null,
                        tint = if (isSelected) Color(0xFF60A5FA) else Color(0xFF9CA3AF)
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Column {
                        Text(style.title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                        Text(style.description, color = Color(0xFF9CA3AF), fontSize = 11.sp)
                    }
                }
            }

            HorizontalDivider(color = Color.White.copy(alpha = 0.1f))

            Column {
                Row(modifier = Modifier.fillMaxWidth()) {
                    Text("Velocidade da Voz", color = Color.White, modifier = Modifier.weight(1f))
                    val label = when {
                        settings.voiceSpeechRate < 0.95f -> "Pausada"
                        settings.voiceSpeechRate > 1.15f -> "Rápida"
                        else -> "Normal"
                    }
                    Text(label, color = Color(0xFF60A5FA), fontWeight = FontWeight.Bold, fontSize = 12.sp)
                }
                Slider(
                    value = settings.voiceSpeechRate,
                    onValueChange = { rate ->
                        AppStateRepository.updateSettings(context) { it.copy(voiceSpeechRate = rate) }
                    },
                    valueRange = 0.80f..1.40f
                )
            }
        }
    }
}

// MARK: - ABA 5: HISTÓRICO DE OFERTAS LIDAS
@Composable
private fun HistoryTabView(
    history: List<RideAnalysis>,
    acceptedRides: List<RideAnalysis>,
    onInspectOCR: (RideAnalysis) -> Unit
) {
    val context = LocalContext.current

    if (history.isEmpty()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 40.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Icon(
                imageVector = Icons.Default.History,
                contentDescription = null,
                tint = Color(0xFF9CA3AF),
                modifier = Modifier.size(40.dp)
            )
            Text(
                text = "Nenhuma oferta lida ainda neste turno.",
                color = Color(0xFF9CA3AF),
                fontSize = 14.sp
            )
        }
    } else {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "${history.size} Ofertas Registradas",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 14.sp,
                modifier = Modifier.weight(1f)
            )
            Text(
                text = "Limpar Histórico",
                color = Color(0xFFEF4444),
                fontWeight = FontWeight.Bold,
                fontSize = 12.sp,
                modifier = Modifier.clickable {
                    AppStateRepository.clearHistory(context)
                }
            )
        }

        history.forEach { item ->
            val accepted = acceptedRides.any { it.id == item.id } || AppStateRepository.isRideAlreadyAccepted(item)
            val vColor = when (item.verdict) {
                RideVerdict.APPROVED -> Color(0xFF10B981)
                RideVerdict.WARNING -> Color(0xFFF59E0B)
                RideVerdict.REJECTED -> Color(0xFFEF4444)
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF161E2E))
                    .clickable { onInspectOCR(item) }
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(12.dp)
                            .clip(CircleShape)
                            .background(vColor)
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = String.format(
                                Locale("pt", "BR"),
                                "[%s] %s • %.1f km • %d min",
                                item.offer.appSource,
                                formatBRL(item.offer.fareBRL),
                                item.offer.totalDistanceKm,
                                item.offer.totalMinutes
                            ),
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 13.5.sp
                        )
                        Text(
                            text = "Lucro Livre: ${formatBRL(item.netProfitBRL)} (Comb: -${formatBRL(item.fuelCostBRL)})",
                            color = Color(0xFF9CA3AF),
                            fontSize = 11.5.sp
                        )
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text(
                            text = "${formatBRL(item.grossPerKm)}/km",
                            color = vColor,
                            fontWeight = FontWeight.Bold,
                            fontSize = 13.5.sp
                        )
                        Text(
                            text = String.format(Locale("pt", "BR"), "R$ %.0f/h", item.grossPerHour),
                            color = Color(0xFF9CA3AF),
                            fontWeight = FontWeight.Bold,
                            fontSize = 11.5.sp
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "${formatTime(item.offer.timestamp)} • Toque p/ ver leitura",
                        color = Color(0xFF9CA3AF),
                        fontSize = 11.sp,
                        modifier = Modifier.weight(1f)
                    )
                    Button(
                        onClick = { AppStateRepository.acceptRide(context, item) },
                        enabled = !accepted,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF059669),
                            disabledContainerColor = Color(0xFF10B981).copy(alpha = 0.2f)
                        ),
                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                        shape = CircleShape,
                        modifier = Modifier.height(30.dp)
                    ) {
                        Text(
                            text = if (accepted) "✓ Salva em Ganhos" else "+ Aceitei essa Corrida",
                            color = if (accepted) Color(0xFF10B981) else Color.White,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        }
    }
}

// MARK: - MODAIS (LANÇAR CORRIDA MANUAL & DIAGNÓSTICO DO LEITOR)
@Composable
private fun AddManualRideDialog(
    settings: DriverSettings,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    var selectedApp by remember { mutableStateOf("UBER") }
    var fareText by remember { mutableStateOf("") }
    var kmText by remember { mutableStateOf("") }
    var minText by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text("Lançar Corrida Aceita", fontWeight = FontWeight.Bold)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf("UBER", "99", "PARTICULAR").forEach { app ->
                        val isSel = selectedApp == app
                        Box(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (isSel) Color(0xFF2563EB) else Color(0xFF222D42))
                                .clickable { selectedApp = app }
                                .padding(vertical = 8.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(app, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                        }
                    }
                }

                OutlinedTextField(
                    value = fareText,
                    onValueChange = { fareText = it },
                    label = { Text("Valor Recebido (R$) Ex: 18,50") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = kmText,
                    onValueChange = { kmText = it },
                    label = { Text("Distância Total (km) Ex: 6,5") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                OutlinedTextField(
                    value = minText,
                    onValueChange = { minText = it },
                    label = { Text("Tempo Total (minutos) Ex: 15") },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    val fare = fareText.replace(",", ".").toDoubleOrNull() ?: 0.0
                    val km = kmText.replace(",", ".").toDoubleOrNull() ?: 0.0
                    val mins = minText.toIntOrNull() ?: 10
                    if (fare > 0 && km > 0) {
                        val offer = RideOfferPayload(
                            appSource = selectedApp,
                            fareBRL = fare,
                            pickupDistanceKm = 0.0,
                            tripDistanceKm = km,
                            totalDistanceKm = km,
                            pickupMinutes = 0,
                            tripMinutes = max(mins, 1),
                            totalMinutes = max(mins, 1),
                            rawRecognizedText = "Corrida lançada manualmente pelo motorista.",
                            timestamp = System.currentTimeMillis() / 1000.0
                        )
                        val analysis = ProfitCalculator.evaluate(offer, settings)
                        AppStateRepository.acceptRide(context, analysis)
                        onDismiss()
                    }
                }
            ) {
                Text("Salvar nos Ganhos")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancelar")
            }
        }
    )
}

@Composable
private fun OCRDebugDialog(
    item: RideAnalysis,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text("Diagnóstico do Leitor (${item.offer.appSource})", fontWeight = FontWeight.Bold)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "Texto exato capturado da tela:",
                    color = Color(0xFF9CA3AF),
                    fontSize = 12.sp
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color(0xFF0B0F17))
                        .padding(12.dp)
                ) {
                    Text(
                        text = item.offer.rawRecognizedText,
                        color = Color.White,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Fechar")
            }
        }
    )
}

// MARK: - COMPARTILHAMENTO E FORMATADORES AUXILIARES
private fun shareShiftReport(
    context: Context,
    ridesCount: Int,
    uberCount: Int,
    ninenineCount: Int,
    grossBRL: Double,
    fuelBRL: Double,
    extraBRL: Double,
    netBRL: Double,
    totalKm: Double,
    totalMinutes: Int,
    avgGrossKm: Double,
    avgNetKm: Double
) {
    val dateStr = SimpleDateFormat("dd/MM/yyyy", Locale("pt", "BR")).format(Date())
    val report = buildString {
        appendLine("📊 *RESUMO DO TURNO ($dateStr) — Uber & 99 Profit*")
        appendLine("━━━━━━━━━━━━━━━━━━━━")
        appendLine("💰 *Lucro Livre no Bolso:* ${formatBRL(netBRL)}")
        appendLine("💵 *Ganho Bruto:* ${formatBRL(grossBRL)}")
        appendLine("⛽ *Combustível:* -${formatBRL(fuelBRL)}")
        if (extraBRL > 0) {
            appendLine("🍔 *Gasto Extra:* -${formatBRL(extraBRL)}")
        }
        appendLine("━━━━━━━━━━━━━━━━━━━━")
        appendLine("🚗 *Corridas:* $ridesCount (Uber: $uberCount • 99: $ninenineCount)")
        appendLine("🛣️ *KM Total:* ${String.format(Locale("pt", "BR"), "%.1f km", totalKm)}")
        appendLine("⏱️ *Tempo em Viagens:* ${formatDuration(totalMinutes)}")
        appendLine("📈 *Média Bruta:* ${formatBRL(avgGrossKm)}/km")
        appendLine("✅ *Média Livre:* ${formatBRL(avgNetKm)}/km")
    }
    try {
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, report)
        }
        context.startActivity(Intent.createChooser(sendIntent, "Compartilhar Resumo do Turno"))
    } catch (_: Exception) {
    }
}

private fun formatBRL(value: Double): String {
    return String.format(Locale("pt", "BR"), "R$ %.2f", value)
}

private fun formatDuration(minutes: Int): String {
    if (minutes < 60) return "$minutes min"
    val h = minutes / 60
    val m = minutes % 60
    return if (m > 0) "${h}h ${m}min" else "${h}h"
}

private fun formatTime(timestampSec: Double): String {
    val sdf = SimpleDateFormat("HH:mm", Locale.getDefault())
    return sdf.format(Date((timestampSec * 1000).toLong()))
}
