//
//  Config.swift
//  BioUnlock
//
//  튜닝 파라미터는 전부 여기에만 둔다. 코드 곳곳에 하드코딩하면 나중에 못 고친다.
//

import Foundation
import CoreGraphics

enum FaceIDConfig {

    // MARK: - 카메라

    /// 노출/화이트밸런스가 수렴하기 전 프레임은 임베딩을 오염시키므로 버린다.
    static var sensorWarmupFramesToDrop: Int = 2

    /// 프리뷰 렌더링 비용을 줄이기 위해 N프레임마다 한 번만 화면을 갱신한다.
    static var previewRenderEveryNFrames: Int = 2

    /// 프리뷰로 내보낼 때 축소할 긴 변 픽셀 수.
    static var previewLongEdge: CGFloat = 720

    // MARK: - 자세 추정
    //
    // Vision의 yaw/pitch/roll은 양자화돼 있고 pitch는 nil이라 랜드마크에서 직접 계산한다.
    // 아래 두 값은 강체 머리 모델의 "코끝 돌출 정도"이고, 실측으로 보정한다.

    /// 코끝이 눈선 평면보다 앞으로 나온 거리 / 두 눈 사이 거리.
    ///
    /// 실측 보정: 큰 회전 프레임에서 눈 간격 축소(cos θ)로 각도를 독립 측정하고
    /// yawProxy = ratio·tan θ 를 역산. 18프레임 중앙값 0.221, 좌 0.223 / 우 0.219로 일치.
    /// 검산: yawProxy 0.333 → 계산 56.5°, 눈간격 측정 56.5°.
    static var noseDepthRatio: Double = 0.22

    /// pitch용. 아직 실측 미보정 — 위아래 끄덕임 로그로 같은 방식으로 잡아야 한다.
    static var noseDepthRatioVertical: Double = 0.75

    // MARK: - 사용자별 중립 보정
    //
    // 얼굴 비대칭과 착석 위치 때문에 정면을 봐도 원본값이 0으로 떨어지지 않는다.
    // 실측에서 정면 yaw 중앙값이 -0.05 rad 만큼 치우쳤다.
    // 등록 중 center 포즈에서 측정해 그 사람 프로필에 저장하고, 등록 세션 동안만
    // 여기 전역값에 반영한다(FaceProfileStore.applyCalibration 참고).
    //
    // 이 값은 '등록 중 포즈 버킷 판정'에만 쓰인다 — 실시간 언락 판정(임베딩
    // 코사인 유사도)에는 전혀 영향을 주지 않으므로 여러 사람이 이 전역값을
    // 돌아가며 쓰더라도 보안에는 영향이 없다. 다만 등록 정확도(포즈 인식)에는
    // 영향을 주므로, 새 사람이 등록을 시작할 때는 반드시 기본값으로 리셋해야
    // 한다 — 안 그러면 이전에 등록한 다른 사람 기준으로 각도가 틀어진다.

    /// 정면일 때의 yawProxy. 이만큼 빼고 각도를 계산한다.
    static var yawProxyNeutral: Double = 0.0
    /// 정면일 때 (눈→코끝) / (눈→입) 비율. 실측 0.6211 / 0.6318 → 0.625.
    static var pitchNeutralRatio: Double = 0.625

    /// 보정 전 기본값. 새 등록 세션을 시작할 때 이 값으로 되돌려서, 이전에
    /// 등록한 다른 사람의 보정값이 남아 포즈 버킷 판정을 어긋나게 하는 걸 막는다.
    static let yawProxyNeutralDefault: Double = 0.0
    static let pitchNeutralRatioDefault: Double = 0.625

    // MARK: - 거리 (눈 간격, 이미지 폭 대비)
    //
    // 실측 기준 정면 편안한 거리에서 io ≈ 0.082~0.087.

    static var interocularMin: CGFloat = 0.055
    static var interocularMax: CGFloat = 0.130
    /// 이보다 작으면 얼굴이 너무 멀어 정렬 품질을 보장할 수 없다.
    static var interocularFloor: CGFloat = 0.030

    // MARK: - 정렬 / 전처리 (Phase 2)

    static var alignedFaceSize: Int = 112

    /// 라플라시안 분산 임계값. 절대 스케일이 루마 범위(0~255)와 해상도에 의존한다.
    ///
    /// 실측(112x112 정렬 얼굴, 가우시안 블러 반경별 평균):
    ///   원본 695 / 0.5px 296 / 1.0px 49 / 1.5px 16 / 2.0px 7
    /// 0.5~1.0px 사이가 절벽이라 여기를 기준으로 잡는다.
    /// 등록은 더 엄격하게 — 흐린 샘플이 프로필에 들어가면 이후 인증이 전부 느슨해진다.
    static var enrollmentBlurThreshold: Float = 300
    static var authBlurThreshold: Float = 120

    /// 노출 정규화에서 위아래로 잘라낼 비율.
    static var exposureClipPercentile: Float = 0.01

    /// CLAHE 타일 격자(112는 8로 나누어떨어져야 한다)와 클립 한계.
    ///
    /// clipLimit 3.0 + 무보정 이득은 살색을 주황으로 밀어냈다(채도 0.253→0.308).
    /// 임베딩이 색에 민감하므로 강도를 낮추고 이득 자체를 제한한다.
    static var claheTiles: Int = 8
    static var claheClipLimit: Float = 2.0
    /// 평활화 결과를 원본과 섞는 비율. 1.0이면 CLAHE를 그대로 적용.
    static var claheStrength: Float = 0.6
    /// 채널별 이득 상하한. 색이 튀는 것을 막는다.
    static var claheGainMin: Float = 0.70
    static var claheGainMax: Float = 1.60

    /// 임베딩에 CLAHE 결과를 쓸지.
    ///
    /// 실측(동일인 3프레임): raw끼리 0.984 vs clahe끼리 0.954.
    /// 두 얼굴 인식 모델(ArcFace, SFace) 모두 정렬+정규화만 한 이미지로 학습돼
    /// 있어 CLAHE 가 입력을 학습 분포 밖으로 밀어낸다. 좋은 조명에서는 명확히 손해다.
    /// 저조도/역광 데이터를 확보하면 다시 재보고 결정할 것.
    static var embedUseCLAHE: Bool = false

    /// 정렬 잔차(픽셀) 상한. 이보다 크면 5점이 유사변환으로 설명되지 않는 상태다.
    static var alignmentResidualMax: CGFloat = 6.0

    // MARK: - 안티스푸핑 (Phase 4)

    /// 안티스푸핑 사용 여부. 끄면 사진 한 장으로 잠금이 열린다.
    static var antiSpoofEnabled: Bool = true

    /// 실물 판정 임계값. '두 모델 최소값'을 '창 최소값'으로 집계한 값과 비교한다.
    ///
    /// 실측(이 카메라, 폰 화면 재생 공격), 모델 최소값 기준:
    ///   실물 351프레임 → 최소 0.151(이상치 1개), 그다음 0.715, p1 0.743, 중앙 0.998
    ///   위조  96프레임 → 최대 0.001
    ///   0.20~0.70 어디를 잡아도 FRR 0.28%(그 이상치 1프레임) / FAR 0%.
    ///
    /// 0.50 을 택한 이유: FRR 은 0.20 일 때와 같은데 위조 최고값 대비 500배 여유가
    /// 생긴다. 아직 시험하지 않은 공격(인쇄물, 고해상도 디스플레이, 동영상 재생,
    /// 3D 마스크)에 대비해 여유를 크게 두는 쪽이 낫다.
    ///
    /// 이전 값 0.30 은 '두 모델 평균 + 이동평균' 집계 기준이었고, 그 집계로는
    /// 사진 공격이 실제로 통과했다(raw 0.0117, 평균 0.4702). 집계를 바꾸면서 재보정했다.
    static var livenessThreshold: Float = 0.50

    /// 판정 창(프레임). 이 창의 '최소값'이 임계값을 넘어야 실물로 본다.
    /// 즉 최근 N프레임이 모두 실물이어야 통과한다. 한 프레임만 위조여도 막힌다.
    static var livenessWindowFrames: Int = 5

    /// 모델 입력 80x80 크롭을 PNG 로 떨군다(진단용).
    static var dumpAntiSpoofCrops: Bool = false

    /// 3클래스 출력 중 '실물'에 해당하는 인덱스. 정답이 있는 샘플로 확정해야 한다.
    static var livenessRealClassIndex: Int = 1

    /// 크롭 배율은 모델이 학습된 값(2.7 / 4.0)을 그대로 쓴다.
    /// AntiSpoofDetector 안에 모델과 짝지어 두었다 — 여기서 바꾸면 안 된다.

    // MARK: - 등록 (Phase 3)

    /// 버킷마다 모을 후보 프레임 수. 이 중 가장 선명한 것만 남긴다.
    static var framesPerPose: Int = 4

    /// 후보 채택 최소 간격(초).
    ///
    /// 이게 없으면 30fps에서 연속 4프레임(0.13초)을 모으게 된다. 거의 같은 사진
    /// 네 장이라 다중 샘플의 의미가 사라지고 '가장 선명한 것 고르기'도 무의미해진다.
    /// 간격을 두면 자연스러운 미세 움직임·표정 변화가 샘플에 들어온다.
    static var minSampleInterval: TimeInterval = 0.25

    /// 버킷별로 프로필에 남길 샘플 수. 정면은 인증에서 가장 많이 쓰이므로 더 남긴다.
    static func samplesToKeep(for bucket: FacePoseBucket) -> Int {
        switch bucket {
        case .center: return 2
        default: return 1
        }
    }

    // MARK: - 대조 (Phase 5)

    /// 본인/타인 점수 분포 실측으로 검증된 값.
    ///
    /// ArcFace(512d) 기준 최초 검증:
    ///   타인: LFW 5675명 12994장 → 최고 0.2780, p99.9 0.2083
    ///   본인: 실사용 프레임      → 최저 0.7108, p1 0.7510, 중앙 0.8624
    ///
    /// SFace(128d) 로 교체(배포용 라이선스 문제로 ArcFace 폐기) 후 재검증,
    /// 실제 등록된 프로필(10샘플)로 LFW 를 다시 채점:
    ///   타인: LFW 5675명 12994장 → 최고 0.3715, p99.9 0.3210
    ///   본인: 실사용 잠금 해제   → 0.9325, 0.9413
    ///   0.40~0.60 어디를 잡아도 FAR 0%. 두 모델 모두 0.48 에서 여유가 충분해 유지.
    ///
    /// 주의: LFW 는 '남남' 오인식만 측정한다. 사진·화면 재생 공격은 전혀 다루지 않으며
    /// 본인 사진은 이 임계값을 그대로 통과한다. 그 방어는 전적으로 안티스푸핑(Phase 4)에 있다.
    static var unlockIdentityThreshold: Float = 0.48
    static var requiredConsecutiveFrames: Int = 3

    // MARK: - 잠금 해제 (Phase 5)

    /// 주입 후 해제됐는지 확인하기까지 기다리는 시간.
    static var unlockRetryDelay: TimeInterval = 0.8
    /// 총 주입 시도 횟수. 무한 재시도는 계정 잠김을 부른다.
    static var unlockMaxAttempts: Int = 2

    /// 비밀번호 입력 전 필드를 비우려고 보내는 백스페이스 횟수.
    ///
    /// 노트북을 열 때 트랙패드·키보드 플렉스로 임의의 키가 한 번씩 눌리는 경우가
    /// 있다. 그 잔여 문자가 비밀번호 필드에 남은 채로 우리가 비밀번호를 이어 치면
    /// "잔여문자+비밀번호"가 돼 결국 틀린 비밀번호로 로그인 실패한다.
    /// 필드가 이미 비어 있으면 백스페이스는 아무 일도 하지 않으므로 안전하다.
    static var unlockClearKeystrokes: Int = 24

    /// 대조 점수 = 최고 유사도·max + 중심 유사도·centroid.
    /// 최고값만 쓰면 운 좋은 샘플 하나로 뚫리고, 중심만 쓰면 포즈 변화에 약해진다.
    static var identityMaxWeight: Float = 0.85
    static var identityCentroidWeight: Float = 0.15

    // MARK: - 디버그

    static var enableDebugImageCapture: Bool = false
    /// 시작할 때 임베딩 자가진단을 돌린다(기준 구현과 벡터 대조용).
    static var runEmbedderSelfTest: Bool = false
    /// 정렬 결과를 PNG 로 떨굴 프레임 번호.
    static var debugCaptureFrames: Set<Int> = [90, 150, 210]

    /// 자세 각도 원본값을 ~/Library/Logs/BioUnlock.log 에 남긴다. 튜닝 끝나면 끌 것.
    static var enablePoseLogging: Bool = true
}
