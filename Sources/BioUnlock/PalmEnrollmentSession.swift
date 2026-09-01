//
//  PalmEnrollmentSession.swift
//  BioUnlock
//
//  손금 등록. 손을 떼었다 다시 올리는 걸 여러 번 반복하며 찍는다.
//
//  왜 한 번에 몰아 찍으면 안 되는가
//  --------------------------------
//  처음엔 12장을 연속으로 찍고 '서로 가장 잘 맞는 것'만 골랐다. 숫자는 좋아졌지만
//  (내부일관성 0.804) 정작 인증이 안 됐다 — 23초 뒤 손을 다시 올리니 0.523.
//  한 순간의 거의 동일한 프레임만 남겨서 그 자세에 과적합된 것이다. 서로 잘 맞는
//  것만 고르는 선별이 오히려 자연스러운 변화를 버리고 있었다.
//
//  인증에서 이기려면 '한 자세를 정밀하게'가 아니라 '여러 자세를 두루' 담아야 한다.
//  그래서 회차를 나누고, 회차 사이에는 손이 프레임에서 사라져야 다음으로 넘어간다
//  — 사용자가 실제로 손을 떼었다 다시 올리게 강제하는 장치다. 얼굴 등록이 포즈
//  버킷을 돌며 찍는 것과 같은 논리다.
//
//  선별은 '완전히 엉뚱한 프레임만 버리는' 수준으로만 한다(다른 샘플 하나와도
//  안 맞으면 제외). 더 엄격하게 하면 다시 과적합으로 돌아간다.
//

import Foundation
import Combine
import UnlockKit
import Unlockpalm

@MainActor
final class PalmEnrollmentSession: ObservableObject {

    enum Step: Equatable {
        case idle
        /// 이번 회차의 샘플을 담는 중.
        case collecting(round: Int)
        /// 다음 회차로 가기 전 손을 떼기를 기다리는 중.
        case waitingForLift(nextRound: Int)
        case done(Int)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var collected: Int = 0
    /// 게이트에 막혀 샘플을 못 담고 있을 때 그 이유. UI 안내용.
    @Published private(set) var blockedReason: String = ""

    private var candidates: [PalmCode] = []
    private var lastAccepted = Date.distantPast
    private var handGoneSince: Date?

    var isActive: Bool {
        switch step {
        case .collecting, .waitingForLift: return true
        default: return false
        }
    }

    private var targetTotal: Int {
        PalmConfig.enrollmentRounds * PalmConfig.samplesPerRound
    }

    var progress: Double { Double(collected) / Double(max(1, targetTotal)) }

    /// 지금 사용자가 뭘 해야 하는지. 화면 문구로 그대로 쓴다.
    var instruction: String {
        switch step {
        case .collecting(let r):
            return "\(r + 1)/\(PalmConfig.enrollmentRounds)회차 — 손바닥을 대고 계세요"
        case .waitingForLift(let r):
            return "손을 떼었다가 다시 올려주세요 (\(r + 1)/\(PalmConfig.enrollmentRounds)회차)"
        default:
            return ""
        }
    }

    func start() {
        candidates.removeAll()
        collected = 0
        blockedReason = ""
        lastAccepted = .distantPast
        handGoneSince = nil
        step = .collecting(round: 0)
        DiagnosticLog.write(
            "palm 등록 시작 (\(PalmConfig.enrollmentRounds)회차 × \(PalmConfig.samplesPerRound)장, 회차마다 손을 뗀다)")
    }

    func cancel() {
        candidates.removeAll()
        collected = 0
        blockedReason = ""
        handGoneSince = nil
        step = .idle
    }

    /// 손금을 계산한 프레임마다 메인 스레드에서 불린다.
    func feed(_ palm: PalmFrameResult) {
        switch step {
        case .collecting(let round):    collect(palm, round: round)
        case .waitingForLift(let next): awaitLift(palm, nextRound: next)
        default:                        return
        }
    }

    // MARK: - 회차 진행

    private func collect(_ palm: PalmFrameResult, round: Int) {
        if let reason = palm.guidance {
            blockedReason = reason
            return
        }
        guard let code = palm.code else { return }
        blockedReason = ""

        // 연속 프레임을 그대로 담으면 거의 같은 사진이 된다.
        guard Date().timeIntervalSince(lastAccepted) >= PalmConfig.enrollmentSampleInterval else { return }

        lastAccepted = Date()
        candidates.append(code)
        collected = candidates.count
        DiagnosticLog.write(String(format: "palm 후보 %d/%d (%d회차) 텍스처=%.3f",
                                   collected, targetTotal, round + 1, palm.salience))

        guard candidates.count >= (round + 1) * PalmConfig.samplesPerRound else { return }

        let nextRound = round + 1
        if nextRound >= PalmConfig.enrollmentRounds {
            finalize()
        } else {
            handGoneSince = nil
            step = .waitingForLift(nextRound: nextRound)
        }
    }

    /// 손이 실제로 프레임을 벗어났다가 돌아와야 다음 회차를 시작한다.
    /// 잠깐 흔들려 인식이 끊긴 걸 '뗐다'로 오해하지 않도록 일정 시간 유지를 요구한다.
    private func awaitLift(_ palm: PalmFrameResult, nextRound: Int) {
        let handPresent = palm.location.verdict != .noHand
        if handPresent {
            handGoneSince = nil
            blockedReason = ""
            return
        }
        let since = handGoneSince ?? Date()
        handGoneSince = since
        guard Date().timeIntervalSince(since) >= PalmConfig.enrollmentLiftSeconds else { return }

        lastAccepted = .distantPast
        handGoneSince = nil
        step = .collecting(round: nextRound)
    }

    // MARK: - 마무리

    /// 완전히 엉뚱한 샘플만 버린다. '서로 가장 잘 맞는 것만' 고르면 다시
    /// 과적합되므로, 다른 샘플 하나와도 안 맞는 것만 제외한다.
    private func finalize() {
        let n = candidates.count
        guard n >= 2 else {
            fail("샘플을 모으지 못했습니다")
            return
        }

        var pair = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = PalmMatcher.score(candidates[i], candidates[j]) ?? 0
                pair[i][j] = s; pair[j][i] = s
            }
        }

        let floor = PalmConfig.enrollmentValidityFloor
        let kept = (0..<n).filter { i in
            (0..<n).contains { $0 != i && pair[i][$0] >= floor }
        }

        guard kept.count >= PalmConfig.enrollmentMinKeptSamples else {
            let best = pair.flatMap { $0 }.max() ?? 0
            DiagnosticLog.write(String(
                format: "palm 등록 실패 — 유효 샘플 %d개(최소 %d) 최고쌍=%.3f 기준=%.2f",
                kept.count, PalmConfig.enrollmentMinKeptSamples, best, floor))
            fail("손금이 일정하게 안 잡힙니다 — 10~12cm 거리와 조명을 확인하고 다시 시도하세요")
            return
        }

        let codes = kept.map { candidates[$0] }
        PalmProfileStore.shared.register(PalmProfile(codes: codes))

        // 여기서 보는 값은 '얼마나 다양한가'다. 예전처럼 높기만 하면 오히려
        // 과적합 신호라, 최저값이 적당히 낮은 게 정상이다.
        var sims: [Float] = []
        for a in 0..<kept.count {
            for b in (a + 1)..<kept.count { sims.append(pair[kept[a]][kept[b]]) }
        }
        let minSim = sims.min() ?? 0
        let avgSim = sims.isEmpty ? 0 : sims.reduce(0, +) / Float(sims.count)
        DiagnosticLog.write(String(
            format: "palm 등록 완료 후보=%d 채택=%d 샘플간 평균=%.3f 최저=%.3f (임계 %.2f)",
            n, codes.count, avgSim, minSim, PalmConfig.matchThreshold))

        step = .done(codes.count)
    }

    private func fail(_ reason: String) {
        candidates.removeAll()
        collected = 0
        step = .failed(reason)
    }
}
