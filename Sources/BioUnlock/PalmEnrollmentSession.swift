//
//  PalmEnrollmentSession.swift
//  BioUnlock
//
//  손금 등록. 후보를 넉넉히 모은 뒤 '서로 잘 맞는 것들'만 골라 등록한다.
//
//  왜 고르는 절차가 필요한가
//  ------------------------
//  그냥 5장을 받아 등록했더니 서로 어긋난 샘플이 그대로 들어갔다(실측 내부일관성
//  0.516 — 무작위 수준). 등록 샘플끼리 안 맞으면 어떤 프레임을 들이대도 통과할 수
//  없는 템플릿이 된다. 그런데 그 사실이 등록 시점에는 드러나지 않아서, 사용자는
//  "등록은 됐는데 인식이 안 된다"로 겪게 된다.
//
//  후보를 12장 모으고 상호 점수가 기준 이상인 것만 남긴다. 남는 게 부족하면
//  조용히 등록하지 않고 실패시킨다 — 손이 흔들렸다는 걸 그 자리에서 알려준다.
//
//  왜 여러 장인가: 참조가 한 장이면 등록 당시 자세에서 조금만 벗어나도 점수가
//  무너진다. 여러 장 중 '가장 잘 맞는 것'을 쓰면 그 출렁임의 아래쪽 꼬리가 올라간다.
//

import Foundation
import Combine
import UnlockKit
import Unlockpalm

@MainActor
final class PalmEnrollmentSession: ObservableObject {

    enum Step: Equatable {
        case idle
        case collecting
        case done(Int)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var collected: Int = 0
    /// 게이트에 막혀 샘플을 못 담고 있을 때 그 이유. UI 안내용.
    @Published private(set) var blockedReason: String = ""

    private var candidates: [PalmCode] = []
    private var lastAccepted = Date.distantPast

    var isActive: Bool { step == .collecting }

    var progress: Double {
        Double(collected) / Double(max(1, PalmConfig.enrollmentCandidateCount))
    }

    func start() {
        candidates.removeAll()
        collected = 0
        blockedReason = ""
        lastAccepted = .distantPast
        step = .collecting
        DiagnosticLog.write("palm 등록 시작 (후보 \(PalmConfig.enrollmentCandidateCount)장 수집 후 일관된 것만 채택)")
    }

    func cancel() {
        candidates.removeAll()
        collected = 0
        blockedReason = ""
        step = .idle
    }

    /// 손금을 계산한 프레임마다 메인 스레드에서 불린다.
    func feed(_ palm: PalmFrameResult) {
        guard step == .collecting else { return }

        if let reason = palm.guidance {
            blockedReason = reason
            return
        }
        guard let code = palm.code else { return }
        blockedReason = ""

        // 연속 프레임을 그대로 담으면 거의 같은 사진 N장이 된다.
        guard Date().timeIntervalSince(lastAccepted) >= PalmConfig.enrollmentSampleInterval else { return }

        lastAccepted = Date()
        candidates.append(code)
        collected = candidates.count
        DiagnosticLog.write(String(format: "palm 후보 %d/%d 텍스처=%.3f 살색=%.2f",
                                   collected, PalmConfig.enrollmentCandidateCount,
                                   palm.salience, palm.skinFraction))

        guard candidates.count >= PalmConfig.enrollmentCandidateCount else { return }
        finalize()
    }

    /// 후보들 중 '서로 잘 맞는 것들'만 골라 등록한다.
    ///
    /// 이게 없으면 서로 어긋난 샘플이 그대로 등록돼(실측 내부일관성 0.516)
    /// 어떤 프레임을 들이대도 통과할 수 없는 템플릿이 만들어진다. 등록 시점에
    /// 걸러내면 그 상황이 구조적으로 불가능해지고, 사용자도 즉시 알 수 있다.
    ///
    /// 고르는 방법: 후보마다 '나머지 중 몇 개와 잘 맞는지'를 세고, 가장 많이
    /// 맞는 후보를 중심으로 삼아 그와 잘 맞는 것들만 남긴다. 가장 큰 상호
    /// 일관 집합을 정확히 찾는 건 조합 문제라 비싸고, 이 근사로 충분하다.
    private func finalize() {
        let n = candidates.count
        guard n >= 2 else {
            fail("샘플을 모으지 못했습니다")
            return
        }

        var pairScore = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = PalmMatcher.score(candidates[i], candidates[j]) ?? 0
                pairScore[i][j] = s
                pairScore[j][i] = s
            }
        }

        let floor = PalmConfig.enrollmentConsistencyFloor
        var bestCenter = 0, bestCount = -1
        for i in 0..<n {
            let count = (0..<n).filter { $0 != i && pairScore[i][$0] >= floor }.count
            if count > bestCount { bestCount = count; bestCenter = i }
        }

        var kept = [bestCenter] + (0..<n).filter { $0 != bestCenter && pairScore[bestCenter][$0] >= floor }
        kept.sort()

        guard kept.count >= PalmConfig.enrollmentMinKeptSamples else {
            let best = pairScore.flatMap { $0 }.max() ?? 0
            DiagnosticLog.write(String(
                format: "palm 등록 실패 — 일관된 샘플 %d개(최소 %d) 최고쌍=%.3f 기준=%.2f",
                kept.count, PalmConfig.enrollmentMinKeptSamples, best, floor))
            fail("손이 너무 흔들렸습니다 — 10~12cm 거리에서 같은 자세로 고정하고 다시 시도하세요")
            return
        }

        let codes = kept.map { candidates[$0] }
        PalmProfileStore.shared.register(PalmProfile(codes: codes))

        var sims: [Float] = []
        for a in 0..<kept.count {
            for b in (a + 1)..<kept.count { sims.append(pairScore[kept[a]][kept[b]]) }
        }
        let minSim = sims.min() ?? 0
        let avgSim = sims.isEmpty ? 0 : sims.reduce(0, +) / Float(sims.count)
        DiagnosticLog.write(String(
            format: "palm 등록 완료 후보=%d 채택=%d 내부일관성 평균=%.3f 최저=%.3f (임계 %.2f)",
            n, codes.count, avgSim, minSim, PalmConfig.matchThreshold))

        step = .done(codes.count)
    }

    private func fail(_ reason: String) {
        candidates.removeAll()
        collected = 0
        step = .failed(reason)
    }
}
