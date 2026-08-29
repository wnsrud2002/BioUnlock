//
//  CameraController.swift
//  BioUnlock
//
//  Phase 1: 카메라 캡처 + Vision 얼굴 검출 루프.
//
//  스레딩 규약
//   - sessionQueue : AVCaptureSession 구성/시작/정지 (메인 스레드를 막지 않기 위해)
//   - visionQueue  : 델리게이트 콜백 = 프레임 처리. 직렬 큐라 처리는 자동 serialize 된다.
//   - main         : @Published 갱신만.
//

import AVFoundation
import Vision
import CoreImage
import Combine
import AppKit
import UnlockKit
import Unlockpalm

/// 정렬·전처리 결과. Phase 3의 임베딩 추출이 이걸 그대로 받는다.
struct AlignedFaceResult {
    let raw: CGImage          // 정렬만 한 것
    let processed: CGImage    // 노출 정규화 + CLAHE 까지
    let sharpness: Float
    let residual: CGFloat
    /// L2 정규화된 512차원 임베딩. 게이트를 통과한 프레임에서만 채워진다.
    let embedding: [Float]?
    /// 원본 + 좌우반전 평균. 등록 중일 때만 계산한다(프레임당 추론 2회).
    let embeddingTTA: [Float]?
    /// 실물 판정. nil 이면 안티스푸핑이 꺼져 있거나 평가하지 못한 상태다.
    let spoof: AntiSpoofResult?

    var passesAlignment: Bool { residual <= FaceIDConfig.alignmentResidualMax }
    var passesAuthGate: Bool { passesAlignment && sharpness >= FaceIDConfig.authBlurThreshold }
    var passesEnrollmentGate: Bool { passesAlignment && sharpness >= FaceIDConfig.enrollmentBlurThreshold }
}

/// 초근접 손금 프레임 하나의 결과.
///
/// 랜드마크를 쓰지 않는다 — 손금이 보이는 거리에서는 손이 프레임을 넘쳐
/// Vision HandPose 가 손을 아예 못 찾기 때문이다(실측으로 확인). 화면 중앙을
/// 그대로 ROI 로 쓰고, 회전만 이미지 구조에서 정규화한다. PalmCloseRange 참고.
struct PalmFrameResult {
    /// 화면에 보여줄 ROI(회전 정규화·CLAHE 까지 적용된 상태).
    let roiImage: CGImage
    /// 이 프레임에서 뽑은 CompCode. 인코딩은 프레임당 한 번만 한다.
    let code: PalmCode
    let skinFraction: Float
    let salience: Float

    var passesSkinGate: Bool { skinFraction >= PalmConfig.minSkinFraction }
    var passesTextureGate: Bool { salience >= PalmConfig.minRoiSalience }
    /// 등록·매칭 모두 이 게이트를 통과한 프레임만 쓴다.
    var passesAllGates: Bool { passesSkinGate && passesTextureGate }
}

final class CameraController: NSObject, ObservableObject {

    // MARK: - UI가 관찰하는 상태 (메인 스레드에서만 갱신)

    @Published private(set) var previewImage: CGImage?
    @Published private(set) var face: FaceFrameInfo?
    @Published private(set) var aligned: AlignedFaceResult?
    @Published private(set) var palm: PalmFrameResult?

    /// 프레임마다 메인 스레드에서 불린다. 등록 세션이 여기에 붙는다.
    var onFrame: ((FaceFrameInfo, AlignedFaceResult) -> Void)?
    /// 손바닥 대조 결과 — 게이트를 통과한 프레임 중 PalmConfig.matchEveryNFrames째만
    /// 실제로 계산해서 부른다(그 외 프레임은 아예 호출하지 않는다. nil 콜백과
    /// "이번엔 계산 안 함"을 구분해야 UnlockService의 연속 카운터가 애먼 타이밍에
    /// 리셋되지 않는다).
    var onPalmMatch: ((Float?) -> Void)?
    /// 손금을 계산한 프레임마다 메인 스레드에서 불린다. 등록 세션이 여기에 붙는다.
    /// 게이트 판정은 붙는 쪽이 한다 — 등록은 "왜 안 담기는지" 안내해야 해서
    /// 게이트를 통과 못 한 프레임도 봐야 하기 때문이다.
    var onPalmFrame: ((PalmFrameResult) -> Void)?
    @Published private(set) var fps: Double = 0
    @Published private(set) var status: String = "대기 중"
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var deviceName: String = "-"

    // MARK: - 캡처 파이프라인

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(label: "tech.biounlock.session", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "tech.biounlock.vision", qos: .userInitiated)

    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false,
        .highQualityDownsample: true
    ])

    /// visionQueue 전용. 매 프레임 새로 만들지 않는다.
    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        return r
    }()

    // visionQueue 전용. 매 프레임 재할당하면 30fps에서 그대로 비용이 된다.
    private var alignedPixels = [UInt8]()
    private var rawPixels = [UInt8]()
    /// 실물 점수 평활화 창. visionQueue 전용.
    private var livenessWindow: [Float] = []

    // visionQueue 전용 카운터
    private var framesSeen = 0
    private var fpsCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private var shouldProcess = false
    /// sessionQueue 전용. 세션 구성이 끝났는지, 그리고 켜져 있길 원하는지.
    /// 구성 전에 start() 가 오면 구성 완료 시점에 이어서 켠다.
    private var isConfigured = false
    private var wantsRunning = false
    /// 등록 중에만 TTA를 돌린다. visionQueue 에서만 읽고 쓴다.
    private var enrolling = false
    /// 손금 계산 주기를 세는 카운터. visionQueue 전용.
    private var palmGateFrameCount = 0

    // MARK: - 권한

    /// 권한을 확인하고 세션을 '구성만' 한다. 켜고 끄는 것은 start()/stop() 이 맡는다.
    /// 메뉴바 앱에서는 창이 없는 게 정상 상태라, 구성은 앱 시작 시 한 번 해 두어야 한다.
    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            setStatus("카메라 권한 요청 중…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configure()
                } else {
                    self.setStatus("카메라 권한 거부됨 — 시스템 설정 > 개인정보 보호와 보안 > 카메라")
                }
            }
        case .denied, .restricted:
            setStatus("카메라 권한 없음 — 시스템 설정 > 개인정보 보호와 보안 > 카메라")
        @unknown default:
            setStatus("카메라 권한 상태를 알 수 없음")
        }
    }

    // MARK: - 세션 구성

    private func configure() {
        setStatus("카메라 구성 중…")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch self.configureSession() {
            case .success(let name):
                self.isConfigured = true
                DiagnosticLog.write("camera 구성 완료: \(name)")
                DispatchQueue.main.async { self.deviceName = name }
                // 구성 전에 start() 가 들어와 있었다면 여기서 이어서 켠다.
                if self.wantsRunning {
                    self.beginRunning()
                } else {
                    self.setStatus("준비됨")
                }
            case .failure(let message):
                DiagnosticLog.write("camera 구성 실패: \(message)")
                self.setStatus(message)
            }
        }
    }

    private enum ConfigResult {
        case success(String)
        case failure(String)
    }

    /// sessionQueue에서만 호출할 것.
    private func configureSession() -> ConfigResult {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1280x720

        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { deviceTypes.append(.external) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.position == .front })
                ?? discovery.devices.first
                ?? AVCaptureDevice.default(for: .video) else {
            return .failure("사용 가능한 카메라를 찾지 못했습니다")
        }

        guard let input = try? AVCaptureDeviceInput(device: device) else {
            return .failure("카메라 입력을 열 수 없습니다: \(device.localizedName)")
        }

        session.inputs.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else { return .failure("카메라 입력을 추가할 수 없습니다") }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // 처리보다 프레임이 빨리 들어오므로 밀린 프레임은 버린다(백프레셔 방지).
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: visionQueue)

        session.outputs.forEach { session.removeOutput($0) }
        guard session.canAddOutput(videoOutput) else { return .failure("비디오 출력을 추가할 수 없습니다") }
        session.addOutput(videoOutput)

        if let conn = videoOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            // 셀피 뷰가 자연스럽도록 미러링. 버퍼가 뒤집히므로 yaw 부호도 좌우가 바뀐다.
            conn.isVideoMirrored = true
        }

        return .success(device.localizedName)
    }

    // MARK: - 제어

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            guard self.isConfigured else {
                self.setStatus("카메라 준비 중…")
                return
            }
            self.beginRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            guard self.session.isRunning else { return }
            self.visionQueue.async { self.shouldProcess = false }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.status = "정지됨"
                self.face = nil
                self.aligned = nil
                self.fps = 0
            }
        }
    }

    /// sessionQueue 에서만 호출.
    private func beginRunning() {
        guard !session.isRunning else { return }
        visionQueue.async {
            self.framesSeen = 0
            self.fpsCount = 0
            self.fpsWindowStart = CFAbsoluteTimeGetCurrent()
            self.palmGateFrameCount = 0
            self.shouldProcess = true
        }
        session.startRunning()
        DispatchQueue.main.async {
            self.isRunning = true
            self.status = "실행 중"
        }
    }

    /// 등록 모드 전환. 켜면 프레임마다 좌우반전 추론이 하나 더 돈다.
    func setEnrolling(_ value: Bool) {
        DiagnosticLog.write("camera setEnrolling(\(value)) 요청됨")
        visionQueue.async { [weak self] in
            self?.enrolling = value
            DiagnosticLog.write("camera enrolling = \(value) 적용됨")
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text }
    }

    // MARK: - 프레임 처리 (visionQueue)

    private func process(pixelBuffer: CVPixelBuffer) {
        guard shouldProcess else { return }

        // 노출/화이트밸런스가 수렴하기 전 프레임은 임베딩을 오염시키므로 버린다.
        framesSeen += 1
        guard framesSeen > FaceIDConfig.sensorWarmupFramesToDrop else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var info: FaceFrameInfo?
        do {
            // 손 검출 요청은 더 이상 돌리지 않는다 — 초근접에서는 손이 프레임을
            // 넘쳐 Vision 이 손을 못 찾는다(PalmCloseRange 주석 참고).
            try handler.perform([landmarksRequest])
            // 가장 큰 얼굴 하나만 쓴다.
            if let best = (landmarksRequest.results ?? [])
                .max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
                info = FaceFrameInfo(observation: best)
                if FaceIDConfig.enablePoseLogging, framesSeen % 15 == 0, let i = info {
                    DiagnosticLog.write(String(
                        format: "yaw=%+.3f pitch=%+.3f roll=%+.3f | yawProxy=%+.4f pitchRatio=%.4f io=%.4f w=%.4f eyeRoll=%+.3f pupils=%d median=%d",
                        i.pose.yaw, i.pose.pitch, i.pose.roll,
                        i.pose.yawProxy, i.pose.pitchRatio, i.pose.interocular, i.faceWidth,
                        i.pose.eyeLineRoll,
                        i.keyPoints.usedPupils ? 1 : 0,
                        i.keyPoints.noseTipFromMedianLine ? 1 : 0))
                }
            }
        } catch {
            NSLog("[BioUnlock] Vision 실패: \(error.localizedDescription)")
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        var alignedResult: AlignedFaceResult?
        if let face = info {
            alignedResult = makeAlignedFace(from: ciImage,
                                            landmarks: face.keyPoints,
                                            faceBox: face.boundingBox)
        } else {
            livenessWindow.removeAll()
        }

        // 손금 경로는 무거워서(방향 6개 컨볼루션 + 이동 49회 탐색) 매 프레임 돌리지
        // 않고 N프레임마다 한 번만 돈다. 인코딩은 여기서 한 번만 하고, 그 결과를
        // 화면 표시·등록·대조가 모두 공유한다.
        var palmResult: PalmFrameResult?
        var didCheckPalmMatch = false
        var palmMatchResult: Float?
        palmGateFrameCount += 1
        if palmGateFrameCount % PalmConfig.matchEveryNFrames == 0 {
            palmResult = makeClosePalm(from: ciImage)
            if let palmResult, palmResult.passesAllGates {
                didCheckPalmMatch = true
                palmMatchResult = PalmProfileStore.shared.verify(palmResult.code)
            }
        }

        var image: CGImage?
        if framesSeen % FaceIDConfig.previewRenderEveryNFrames == 0 {
            image = makePreviewImage(from: ciImage)
        }

        // FPS는 1초 창으로 집계.
        fpsCount += 1
        var newFPS: Double?
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 1.0 {
            newFPS = Double(fpsCount) / elapsed
            fpsCount = 0
            fpsWindowStart = now
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.face = info
            self.aligned = alignedResult
            // 손금은 N프레임마다만 계산하므로, 계산 안 한 프레임에서는 직전 값을
            // 유지한다(nil 로 덮으면 UI 가 깜빡인다).
            if let palmResult { self.palm = palmResult }
            if let info, let alignedResult { self.onFrame?(info, alignedResult) }
            if let palmResult { self.onPalmFrame?(palmResult) }
            if didCheckPalmMatch { self.onPalmMatch?(palmMatchResult) }
            if let image { self.previewImage = image }
            if let newFPS { self.fps = newFPS }
        }
    }

    private func makePreviewImage(from ci: CIImage) -> CGImage? {
        let longEdge = max(ci.extent.width, ci.extent.height)
        let scale = longEdge > 0 ? min(1.0, FaceIDConfig.previewLongEdge / longEdge) : 1.0
        let scaled = scale < 1.0
            ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ci
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - 정렬 / 전처리 (visionQueue)

private extension CameraController {

    func makeAlignedFace(from image: CIImage,
                         landmarks: FaceLandmarks5,
                         faceBox: CGRect) -> AlignedFaceResult? {
        let size = FaceIDConfig.alignedFaceSize
        guard let alignedImage = FaceAligner.align(image: image, landmarks: landmarks, size: size) else { return nil }

        let byteCount = size * size * 4
        if alignedPixels.count != byteCount { alignedPixels = [UInt8](repeating: 0, count: byteCount) }

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        alignedPixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ciContext.render(alignedImage,
                             toBitmap: base,
                             rowBytes: size * 4,
                             bounds: bounds,
                             format: .RGBA8,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        // 선명도는 전처리 '전'에 재야 한다. CLAHE가 대비를 올리면 흐린 얼굴도 선명해 보인다.
        let lumaValues = FacePreprocessor.luma(from: alignedPixels, count: size * size)
        let sharpness = FacePreprocessor.laplacianVariance(luma: lumaValues, size: size)
        let residual = FaceAligner.residual(landmarks: landmarks, imageExtent: image.extent, size: size)

        rawPixels = alignedPixels
        guard let rawImage = Self.makeCGImage(rgba: rawPixels, size: size) else { return nil }

        FacePreprocessor.normalizeExposure(pixels: &alignedPixels, size: size)
        FacePreprocessor.applyCLAHE(pixels: &alignedPixels, size: size)
        guard let processedImage = Self.makeCGImage(rgba: alignedPixels, size: size) else { return nil }

        // 게이트를 통과 못 한 프레임은 임베딩할 이유가 없다. 추론 비용도 아낀다.
        var embedding: [Float]?
        var embeddingTTA: [Float]?
        let gatePassed = residual <= FaceIDConfig.alignmentResidualMax
            && sharpness >= FaceIDConfig.authBlurThreshold
        if gatePassed {
            let source = FaceIDConfig.embedUseCLAHE ? alignedPixels : rawPixels
            embedding = FaceEmbedder.shared.embed(rgba: source, size: size)

            // TTA는 등록 때만. 좌우반전본을 함께 평균내면 등록 임베딩이 눈에 띄게 안정된다.
            if enrolling,
               sharpness >= FaceIDConfig.enrollmentBlurThreshold,
               let base = embedding,
               let flipped = FaceEmbedder.shared.embed(rgba: source, size: size, flipped: true) {
                embeddingTTA = VectorMath.average([base, flipped])
            }
        }

        // 실물 판정은 정렬된 얼굴이 아니라 '원본 프레임의 얼굴 주변'을 본다.
        var spoof: AntiSpoofResult?
        if FaceIDConfig.antiSpoofEnabled, gatePassed {
            let windowed = livenessWindow.min()
            if let r = AntiSpoofDetector.shared.evaluate(image: image, faceBox: faceBox, smoothed: windowed) {
                livenessWindow.append(r.realScore)
                if livenessWindow.count > FaceIDConfig.livenessWindowFrames {
                    livenessWindow.removeFirst()
                }
                // 창이 다 차기 전에는 실물로 보지 않는다(fail-closed).
                // 창의 '최소값'을 쓰므로 최근 N프레임이 모두 실물이어야 통과한다.
                let full = livenessWindow.count >= FaceIDConfig.livenessWindowFrames
                let worst = livenessWindow.min() ?? 0
                spoof = AntiSpoofResult(realScore: r.realScore,
                                        smoothScore: worst,
                                        isReal: full && worst >= FaceIDConfig.livenessThreshold,
                                        perModel: r.perModel)
            }
        }

        let result = AlignedFaceResult(raw: rawImage,
                                       processed: processedImage,
                                       sharpness: sharpness,
                                       residual: residual,
                                       embedding: embedding,
                                       embeddingTTA: embeddingTTA,
                                       spoof: spoof)
        if FaceIDConfig.enablePoseLogging, framesSeen % 15 == 0 {
            var line = String(format: "align sharp=%.1f residual=%.2f", sharpness, residual)
            if let sp = spoof {
                line += String(format: " | live=%.4f wmin=%.4f [%@]",
                               sp.realScore, sp.smoothScore,
                               sp.perModel.map { String(format: "%.3f", $0) }.joined(separator: ","))
            }
            // 실사용 중 본인 점수 분포를 쌓아둔다. 임계값은 이 분포와 타인 분포로 정해야 한다.
            if let e = embedding, !FaceProfileStore.shared.isEmpty {
                let v = FaceProfileStore.shared.verify(e)
                line += String(format: " | verify=%.4f best=%.4f cen=%.4f name=%@",
                               v.score, v.bestSample, v.centroidScore, v.profileName ?? "-")
            }
            DiagnosticLog.write(line)
        }
        // 정렬이 맞는지는 화면 썸네일만으로 판단할 수 없다. 실제 PNG를 떨궈서 확인한다.
        if FaceIDConfig.enableDebugImageCapture, FaceIDConfig.debugCaptureFrames.contains(framesSeen) {
            Self.dump(result: result, tag: "f\(framesSeen)")
        }
        return result
    }

    /// 초근접 손금 프레임을 만든다. 랜드마크를 쓰지 않는다 — 손금이 보이는
    /// 거리에서는 손이 프레임을 넘쳐 Vision HandPose 가 손을 못 찾기 때문이다.
    ///
    /// 화면 중앙에서 가장 큰 정사각을 잘라 workingSize 로 렌더링하고, 나머지
    /// (회전 정규화 · CLAHE · 인코딩)는 PalmCloseRange 가 등록·인증 공통으로 처리한다.
    func makeClosePalm(from image: CIImage) -> PalmFrameResult? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let side = min(extent.width, extent.height)
        let square = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2,
                            width: side, height: side)
        let w = PalmCloseRange.workingSize
        let scale = CGFloat(w) / side
        let scaled = image
            .cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.origin.x, y: -square.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var pixels = [UInt8](repeating: 0, count: w * w * 4)
        pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ciContext.render(scaled, toBitmap: base, rowBytes: w * 4,
                             bounds: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(w)),
                             format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        guard let (roi, code) = PalmCloseRange.analyze(rgba: pixels) else { return nil }
        guard let roiImage = Self.makeGrayCGImage(luma: roi.luma, size: roi.size) else { return nil }

        return PalmFrameResult(roiImage: roiImage,
                               code: code,
                               skinFraction: roi.skinFraction,
                               salience: roi.salience)
    }

    /// 루마 평면을 화면 표시용 회색조 이미지로. 사용자가 실제로 어떤 그림이
    /// 인코딩되는지 눈으로 봐야 튜닝이 가능하다.
    static func makeGrayCGImage(luma: [Float], size: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) { bytes[i] = UInt8(max(0, min(255, luma[i]))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    static func dump(result: AlignedFaceResult, tag: String) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BioUnlock_Aligned")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (image, name) in [(result.raw, "raw"), (result.processed, "clahe")] {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: dir.appendingPathComponent("\(tag)_\(name).png"))
        }
        DiagnosticLog.write("dump \(tag) → Downloads/BioUnlock_Aligned")
    }

    static func makeCGImage(rgba: [UInt8], size: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: size,
                       height: size,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(pixelBuffer: pixelBuffer)
    }
}
