import Foundation
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

/// Gerencia a janela flutuante de Picture-in-Picture (`AVPictureInPictureController`)
/// usando `AVSampleBufferDisplayLayer` para desenhar em tempo real o card colorido
/// (Verde = Aceitar, Amarelo = Atenção, Vermelho = Recusar) sobre o aplicativo da Uber.
@MainActor
public final class PiPOverlayManager: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {

    @Published public private(set) var isPiPActive: Bool = false
    @Published public private(set) var isPiPPossible: Bool = false

    public let displayLayer = AVSampleBufferDisplayLayer()

    private var pipController: AVPictureInPictureController?
    private var refreshTimer: Timer?
    private var currentAnalysis: RideAnalysis?
    private var statusObservation: NSKeyValueObservation?

    private let canvasSize = CGSize(width: 640, height: 260)

    public override init() {
        super.init()
        setupDisplayLayer()
        setupPiPController()
        startFrameFeedTimer()
    }

    private func setupDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        enqueueRenderedFrame(analysis: nil)
    }

    private func setupPiPController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPPossible = false
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true

        statusObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
            Task { @MainActor in
                self?.isPiPPossible = ctrl.isPictureInPicturePossible
            }
        }

        self.pipController = controller
    }

    public func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            enqueueRenderedFrame(analysis: currentAnalysis)
            pipController.startPictureInPicture()
        }
    }

    public func updateCard(with analysis: RideAnalysis) {
        self.currentAnalysis = analysis
        enqueueRenderedFrame(analysis: analysis)
    }

    private func startFrameFeedTimer() {
        // Mantém o buffer da camada de vídeo alimentado a cada 1s para o iOS manter o PiP ativo
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.enqueueRenderedFrame(analysis: self.currentAnalysis)
            }
        }
    }

    private func enqueueRenderedFrame(analysis: RideAnalysis?) {
        let image = renderCardImage(analysis: analysis)
        guard let sampleBuffer = createSampleBuffer(from: image) else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Renderização Gráfica do Card (Verde / Amarelo / Vermelho)
    private func renderCardImage(analysis: RideAnalysis?) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: canvasSize)

            guard let analysis else {
                // Card inicial aguardando corridas
                UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0).setFill()
                context.fill(rect)

                let borderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), cornerRadius: 20)
                UIColor.systemCyan.withAlphaComponent(0.7).setStroke()
                borderPath.lineWidth = 4
                borderPath.stroke()

                drawText(
                    "UBER PROFIT ATIVO",
                    in: CGRect(x: 24, y: 55, width: canvasSize.width - 48, height: 60),
                    font: .systemFont(ofSize: 42, weight: .black),
                    color: .white,
                    alignment: .center
                )
                drawText(
                    "Monitorando ofertas da Uber em tempo real...",
                    in: CGRect(x: 24, y: 135, width: canvasSize.width - 48, height: 50),
                    font: .systemFont(ofSize: 24, weight: .semibold),
                    color: .systemGray2,
                    alignment: .center
                )
                return
            }

            let bgColor: UIColor
            let badgeText: String
            switch analysis.verdict {
            case .approved:
                bgColor = UIColor(red: 0.06, green: 0.56, blue: 0.24, alpha: 1.0) // Verde Forte
                badgeText = "ACEITAR  •  LUCRO R$ \(String(format: "%.2f", analysis.netProfitBRL).replacingOccurrences(of: ".", with: ","))"
            case .warning:
                bgColor = UIColor(red: 0.78, green: 0.52, blue: 0.02, alpha: 1.0) // Amarelo / Âmbar
                badgeText = "ATENÇÃO  •  LUCRO R$ \(String(format: "%.2f", analysis.netProfitBRL).replacingOccurrences(of: ".", with: ","))"
            case .rejected:
                bgColor = UIColor(red: 0.72, green: 0.10, blue: 0.14, alpha: 1.0) // Vermelho Forte
                badgeText = "RECUSAR  •  LUCRO R$ \(String(format: "%.2f", analysis.netProfitBRL).replacingOccurrences(of: ".", with: ","))"
            }

            bgColor.setFill()
            context.fill(rect)

            // Cabeçalho com veredito e lucro líquido
            let headerRect = CGRect(x: 16, y: 14, width: canvasSize.width - 32, height: 48)
            let headerPath = UIBezierPath(roundedRect: headerRect, cornerRadius: 12)
            UIColor.black.withAlphaComponent(0.28).setFill()
            headerPath.fill()

            drawText(
                badgeText,
                in: CGRect(x: 24, y: 20, width: canvasSize.width - 48, height: 38),
                font: .systemFont(ofSize: 28, weight: .heavy),
                color: .white,
                alignment: .center
            )

            // Valores Gigantes: R$/km e R$/h
            let kmString = String(format: "R$ %.2f/km", analysis.grossPerKm).replacingOccurrences(of: ".", with: ",")
            let hourString = String(format: "R$ %.0f/h", analysis.grossPerHour)

            drawText(
                kmString,
                in: CGRect(x: 24, y: 78, width: 320, height: 85),
                font: .systemFont(ofSize: 54, weight: .black),
                color: .white,
                alignment: .left
            )

            drawText(
                hourString,
                in: CGRect(x: 340, y: 78, width: 276, height: 85),
                font: .systemFont(ofSize: 54, weight: .black),
                color: .white,
                alignment: .right
            )

            // Rodapé com detalhes: Tarifa Bruta | KM Total | Tempo Total | Combustível
            let footerString = String(
                format: "Tarifa R$ %.2f  •  %.1f km total  •  %d min  •  Comb. -R$ %.2f",
                analysis.offer.fareBRL,
                analysis.offer.totalDistanceKm,
                analysis.offer.totalMinutes,
                analysis.fuelCostBRL
            ).replacingOccurrences(of: ".", with: ",")

            drawText(
                footerString,
                in: CGRect(x: 20, y: 192, width: canvasSize.width - 40, height: 45),
                font: .systemFont(ofSize: 22, weight: .bold),
                color: UIColor.white.withAlphaComponent(0.92),
                alignment: .center
            )
        }
    }

    private func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    // MARK: - Conversão UIImage -> CMSampleBuffer
    private func createSampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDesc = formatDescription else { return nil }

        let now = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        if let sBuffer = sampleBuffer,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        return sampleBuffer
    }

    // MARK: - AVPictureInPictureControllerDelegate & PlaybackDelegate
    public func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
    }

    public func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    public func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
