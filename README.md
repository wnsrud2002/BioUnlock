# Unlockface

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Arch](https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-lightgrey)

macOS 노트북 뚜껑을 열면 얼굴로 로그인 화면을 자동으로 통과시켜주는 메뉴바 앱입니다.

macOS는 서드파티 앱이 실제 로그인 인증 경로에 끼어드는 것을 시스템 차원에서 막습니다.
그래서 이 앱은 "생체인증"이 아니라 **얼굴이 등록된 사람과 일치하면, 미리 저장해 둔
로그인 비밀번호를 대신 입력해 주는 자동화**입니다. 아래 [보안 모델](#보안-모델과-한계)에서
이 구조가 뜻하는 바를 반드시 읽어보세요.

만드는 과정에서 실측한 수치와 찾아 고친 버그들은 [ENGINEERING.md](ENGINEERING.md)에
따로 정리했습니다 — Vision의 자세 각도가 왜 못 쓰는 수준인지, 안티스푸핑 모델의
정규화 주석이 실제 코드와 왜 반대였는지, 메뉴바 앱 전환에서 카메라가 20분 넘게
켜져 있던 원인 같은 것들입니다.

## 기능

- 얼굴 인식으로 로그인 화면 자동 통과 (Vision + CoreML, 128차원 임베딩 비교)
- 사진·화면 재생 공격 탐지 (MiniFASNet 안티스푸핑, 두 배율 앙상블)
- 여러 명 등록 지원 — 가족·룸메이트 등 계정 하나를 여러 얼굴로
- 메뉴바 상주, 로그인 시 자동 실행
- 카메라는 필요할 때만 켜짐 (잠금 중 또는 얼굴 등록 화면을 보고 있을 때만)
- 인식 엄격도·연속 프레임 수·위조 탐지 강도를 설정에서 직접 조정 가능

## 요구 사항

- macOS 13 이상
- 카메라가 있는 Mac (내장 또는 외장)
- Universal Binary (Apple Silicon / Intel). Apple Silicon에서 실기 테스트를
  완료했고, Intel은 빌드·서명·실행까지 확인했으나 Intel 실기 테스트는
  하지 못했습니다.

## 설치

### 1) 앱 받기 (권장)

[Releases](../../releases) 페이지에서 최신 `Unlockface-x.y.z.zip`을 내려받습니다.

### 2) 압축 해제 후 Applications로 이동

압축을 풀면 나오는 `Unlockface.app`을 `Applications` 폴더로 옮깁니다.

### 3) 첫 실행 — 반드시 우클릭으로 열기

이 앱은 Apple 정식 개발자 인증서가 아니라 **자체서명**돼 있습니다(Apple 공증
없음). macOS Gatekeeper가 첫 실행을 막는데, 이건 정상입니다:

1. `Applications`에서 **Unlockface.app을 control-클릭(또는 우클릭)**
2. 메뉴에서 **"열기"** 선택
3. "확인되지 않은 개발자" 경고 대화상자에서 **"열기"** 클릭

> ⚠️ Dock이나 더블클릭으로 처음 열면 매번 "손상되었거나 확인할 수 없음"으로
> 차단됩니다. 반드시 위 순서(우클릭 → 열기)로 **한 번만** 통과시키면, 이후
> 로그인 시 자동 실행이나 더블클릭 모두 정상 동작합니다.

첫 실행 시 macOS가 새 바이너리의 코드서명을 처음 평가하느라 몇 초 정도
멈춘 것처럼 보일 수 있습니다(정상입니다 — [ENGINEERING.md](ENGINEERING.md)의
키체인 워밍업 항목 참고). 메뉴바에 얼굴 아이콘이 뜨면 정상적으로 켜진 것입니다.

### 소스에서 직접 빌드하고 싶다면

```
git clone https://github.com/wnsrud2002/Unlockface.git
cd Unlockface
./scripts/build.sh          # 개발용, 현재 아키텍처만, debug
open build/Unlockface.app

# 또는 배포용 유니버설 바이너리 + ZIP
./scripts/package.sh
```

Xcode 없이 Swift 툴체인(Xcode Command Line Tools)만 있으면 됩니다.
모델은 이미 `Models/`에 변환·검증된 상태로 포함돼 있어 Python 없이 바로
빌드됩니다. 모델을 처음부터 다시 만들고 싶다면 `tools/setup.sh`부터
실행하세요.

카메라 권한·키체인 접근 권한은 앱 서명(코드 식별자)에 묶입니다. 소스를
고쳐서 직접 재빌드하는 경우, 매번 다른 임시 서명이 붙지 않도록
`./scripts/setup-signing.sh`로 로컬 개발용 인증서를 한 번 만들어두는 걸
권장합니다 — 안 그러면 재빌드할 때마다 카메라 권한을 다시 물어봅니다.

## 처음 설정하기

메뉴바 아이콘(얼굴 인식 모양) 클릭 → **설정…**

1. **얼굴** 탭에서 이름을 입력하고 등록 시작 → 화면 안내를 따라
   정면 → 왼쪽 → 오른쪽 순으로 고개를 돌립니다. 이어서 위/아래/기울이기/
   거리 조절까지 확장 등록하면 인식률이 더 올라갑니다.
2. **보안** 탭에서 Mac 로그인 비밀번호를 입력하고 "검증 후 저장"을
   누릅니다 — 실제 계정 비밀번호로 검증한 뒤에만 저장됩니다.
3. 같은 탭에서 **접근성 권한**을 요청하고, 시스템 설정에서 허용합니다
   (비밀번호 자동 입력에 반드시 필요합니다).
4. 메뉴바 팝오버에서 **"얼굴로 잠금 해제"**를 켭니다. 세 조건(얼굴 등록·
   비밀번호 저장·접근성 권한)이 모두 충족돼야 켤 수 있습니다.
5. 뚜껑을 닫았다 열거나 `Control+Command+Q`로 화면을 잠그고 테스트해보세요.

가족이나 룸메이트 등 다른 사람도 등록하려면 얼굴 탭에서 같은 방식으로
이름만 다르게 반복하면 됩니다. 등록된 얼굴은 목록에서 개별적으로
삭제할 수 있습니다.

### 완전히 지우고 싶다면

```
rm -rf ~/Library/"Application Support"/tech.unlockface.app
security delete-generic-password -s tech.unlockface.app -a UnlockfaceMasterKey
security delete-generic-password -s tech.unlockface.app -a UnlockfacePasswordKey
security delete-generic-password -s tech.unlockface.app -a UnlockfaceLoginPassword
```

앱 자체를 지우는 것(`Applications`에서 휴지통으로)만으로는 등록된 얼굴
데이터와 키체인 항목이 남습니다.

## 보안 모델과 한계

**이 앱은 Apple의 Face ID/Touch ID 와 다릅니다.** Secure Enclave 를 쓰지 않고,
로그인 비밀번호를 앱이 복원 가능한 형태로 키체인에 암호화해 보관합니다.
얼굴이 일치하면 그 비밀번호를 가상 키보드 입력으로 대신 쳐 넣습니다. 즉 이
앱의 보안은 (1) 얼굴 인식 정확도, (2) 안티스푸핑, (3) 키체인 암호화에 달려
있고, macOS 자체의 생체인증 보안 등급을 대체하지 않습니다.

**얼굴 인식**: LFW 데이터셋 5,675명(12,994장)으로 오인식률을 측정했습니다.
등록한 프로필 기준 타인 최고 유사도 0.37, 실제 사용 시 본인 점수 0.93~0.94 —
기본 임계값(0.48)에서 오인식 0%를 확인했습니다.

**안티스푸핑**: 두 개의 MiniFASNet 모델(배율 2.7배/4.0배)로 화면·사진 재생을
탐지합니다. **폰 화면 재생 공격만 실측 검증했습니다.** 인쇄된 사진, 고해상도
디스플레이, 동영상 재생, 3D 마스크는 검증되지 않았습니다. 설정에서 끌 수
있지만, 끄면 사진 한 장으로 잠금이 열립니다.

**등록 얼굴 데이터**: 원본 이미지는 저장하지 않고, 암호화된 얼굴 임베딩만
`~/Library/Application Support/tech.unlockface.app/`에 둡니다. 암호화 키는
키체인에 별도 보관합니다. 이 앱을 지워도 이 데이터는 남으니, 완전히 지우려면
해당 폴더와 키체인 항목("Unlockface"로 검색)을 함께 삭제하세요.

## 라이선스

이 프로젝트 자체는 [MIT License](LICENSE)입니다.

번들에 포함된 두 사전학습 모델(얼굴 인식 SFace, 안티스푸핑 MiniFASNet)은
Apache License 2.0이며, 출처와 변경 사항은 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)에
명시했습니다.
