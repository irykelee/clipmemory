# ClipMemory v2.4.2

**차세대 macOS 클립보드 관리자 — 원 탭으로 실행, 복사 즉시 검색**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## v1 → v2 주요 개선사항

| 항목 | v1 | v2 |
|------|----|----|
| **상호작용** | 메뉴바 → 메뉴 → 창 열기 (3단계) | Quick Bar 팝업 (1단계) |
| **메인 화면** | 고정 너비, 사이드바 없음 | 고정 사이드바, 유형 자유롭게 전환 |
| **글로벌 핫키** | Cmd+Ctrl+V 전용 | 사용자 지정 녹음 지원 |
| **Quick Bar** | 없음 | 최근 8개 항목 팝업, 검색·복사 즉시 |
| **검색 하이라이트** | 텍스트 위 하이라이트 | 대소문자 구분 없음, 글자 깨짐 없음 |
| **길게 누르기** | 없음 | 0.4s로 전체/민감/이미지 원본 표시 |
| **시간 그룹화** | 없음 | 오늘/어제/이전,折叠 가능 |

---

## 📋 변경 로그

### v2.4.2 (2026-07-18) — 안정성 수정 + 업데이트 이중 채널

- **🌐 업데이트 이중 채널** — GitHub 접근이 안 될 때 jsDelivr 미러로 자동 전환. 업데이트가 있으면 앱이 전면으로 나오며 Dock 배지 표시(gentle reminders)
- **💾 데이터 안전** — 새 클립보드 항목을 즉시 디스크에 기록. 이전에는 500ms 디바운스 동안 kill -9 / 전원 손실 시 유실될 수 있었음
- **🐛 안정성 수정** — SwiftUI "Modifying state during view update" 경고 폭주(초당 수십 건 → 0) 해소. 단축키 점유 시 매 실행마다 반복되던 -9878 오류 로그 중단

### v2.4.1 (2026-07-18) — 업데이트 피드 수정

- **🌐 「업데이트 오류」 수정** — 업데이트 피드를 raw.githubusercontent.com(일부 네트워크에서 접근 불가)에서 GitHub Release 애셋으로 이전하여 업데이트 확인이 즉시 완료됩니다. v2.4.0에서 오류가 표시되면 v2.4.1을 한 번 수동으로 다운로드하세요. 이후 자동 업데이트가 동작합니다

### v2.4.0 (2026-07-18) — 휴지통

- **🗑️ 휴지통(Recycle Bin)** — 삭제한 항목이 즉시 파괴되지 않고 휴지통으로 이동하여 7일간 보관됩니다(설정에서 변경 가능). 이 기간 동안 복원하거나 완전히 삭제할 수 있습니다. 휴지통을 비울 때는 확인 창이 표시되며, 보관 기간이 지난 항목은 자동으로 정리됩니다.
- **✨ 자동 업데이트(Sparkle 2)** — 앱 내 자동 업데이트 확인: 매일 백그라운드 확인 + 설정에서 수동 확인. 업데이트 패키지는 EdDSA 서명으로 검증되며 원클릭으로 설치·재시작됩니다. Homebrew Cask에 auto_updates가 선언되어 있습니다.
- **데이터 안전** — 이미지 파일은 휴지통 항목과 함께 보관되며, 완전히 삭제할 때만 제거됩니다. 자동 정리(trim/만료)는 휴지통을 거치지 않습니다.
- **UI 업데이트** — 사이드바에 「휴지통」 항목 추가(배지로 개수 표시); 삭제 확인 문구를 「휴지통으로 이동」으로 변경; 휴지통 항목에 삭제 시간 표시
- **테스트** — 휴지통 관련 신규 테스트 12개 추가, 모두 통과

### v2.3.0 (2026-07-17) — 태그 시스템 및 데이터 무결성

- **🏷️ 태그 시스템（Tag System）** — 완전한 태그 라이프사이클: 생성 / 삭제 / 커스텀 색상; 사이드바 tag section + 섹션 간 AND / 섹션 내 OR 필터링; 스마트 태그 제안 (NLTagger 기반: 코드 / 이메일 / 자격 증명 / 민감); TagPicker sheet (인라인 chips + 길게 누르기 picker); 삭제 확인 대화상자
- **6건의 데이터 무결성 중대 수정** — saveTimer 스레드 경합 UB; FileStorageBackend 동기 쓰기; flushPendingSaves의 태그 동기 플러시; 레거시 image items 잘못된 암호화 플래그 수정; contentHash backfill; ImageStorage 부분 실패 복구
- **UI 개선** — Welcome window dedupe; Esc로 hotkey recording 취소 (responder에 event 반환); 자정을 넘는 currentDate 자동 새로 고침; Search 모드 그룹 강제 펼침 (키보드 탐색 동기화); pendingMaxItemsReduction typo 수정
- **리팩터링 + 성능** — RTF NSCache; L10n bundle cache; WindowManager 상태 안정화 (@State가 close/reopen 간 유지); windowDidMove/Resize debounce 0.5s; +9 net new tests (241 → 250)

### v2.2.4 (2026-07-16) — 릴리스 위생 관리

- **버전 스탬프와 릴리스 태그 동기화** — `project.yml`의 `MARKETING_VERSION` 및 `CURRENT_PROJECT_VERSION`을 `2.2.4`로 업데이트하고 `project.pbxproj`를 재생성. v2.2.3에서 태그는 컷하지만 버전 번호를 동기화하지 않은教训을 해결
- **Quick Bar 레이블 수정** — Quick Bar "전체 창 열기" 항목에서 오해를 주는 `⌘⌃V` 단축키 레이블을 제거. 글로벌 핫키가 여는 것은 전체 메인 창이며, Quick Bar는 메뉴바 📋 아이콘을 좌클릭하여 열림
- **문서 핫키 설명 정정** — 8개 언어 README의 `Cmd+Ctrl+V` 행을 재작성하여 Quick Bar가 아닌 메인 창을 여는 것을 명확히 설명
- **패키징 스크립트 안전 강화** — `Scripts/package.sh` 기본 버전 인수가 이제 `project.yml`의 `MARKETING_VERSION`을 읽어오며(읽기 실패 시 가드 포함), 인수 없이 호출 시 이전 버전 tarball을 패키징하는 문제 방지

### v2.2.1 (2026-05-19) — 이미지 민감 로직 수정

- **이미지 민감 판단 수정** — 이미지가 크기(50KB)로 자동 마크되지 않도록 수정, 저장은 maxItems 및 수동 정리로 제어
- **컴포넌트 추출** — ContentView를 FlowLayout, LogoView, DateFilterButton, AppPickerRow, ClipboardItemRow로 분리
- **공유 유틸리티** — FontScaling.swift(sz()) 및 DateHelpers.swift(날짜 포맷) 추출
- **NSCache 메모리 압력 처리** — 시스템 메모리 경고 옵저버 추가, 압력 시 캐시をクリア

### v2.2.0 (2026-05-15) — Rich Text 지원

- **RTF 클립보드 캡처** — Rich Text 내용 자동 인식 및 저장
- **Rich Text 렌더링** — NSAttributedString → AttributedString 변환
- **복사 붙여넣기** — .rtf 및 .string 두 가지 클립보드 타입에 동시에 기록
- **사이드바 탭** — 신규 "Rich Text" 카테고리, 아이콘·카운터·유형 필터 포함
- **Quick Bar 표시** — Rich Text 아이콘 + 일반 텍스트 미리보기
- **민감 콘텐츠 마스킹** — Rich Text 항목도 민감 정보 마스킹 지원
- **85 테스트** — 4개의 Rich Text 라운드트립 테스트 포함
- **검색 수정** — Rich Text 검색 기능 수정

### v2.1.5 (2026-05-11) — 프로토콜 추상화 및 UX 개선

- **프로토콜 추상화** — StorageBackend 프로토콜 + MemoryStorageBackend 테스트 백엔드
- **81 테스트** — 테스트 인프라 완료
- **최대 트림 대화상자** — 기록 상한 초과 시 확인 대화상자 표시
- **이미지 플레이스홀더** — 로드 실패 시 엘레강스한 플레이스홀더 표시
- **그룹 작업** — 그룹 수준의 고정 해제/지우기 지원

### v2.1.0 (2026-05-09) — Liquid Glass UI

- Liquid Glass 디자인 언어 — NavigationSplitView 사이드바 + QuickBar 유리 팝업
- 키보드 내비게이션 수정 — 스크롤 및 검색 상자 방향키 처리 수정

---

## 기능 하이라이트

### Quick Bar — 원 탭

메뉴바 아이콘 클릭 → NSPopover로 최근 8개 항목 표시 → 클릭으로 복사/검색/전체 창 열기

### 길게 누르기 0.4s — 제한 없는 미리보기

| 콘텐츠 | 기본 표시 | 길게 누른 후 |
|--------|----------|------------|
| 일반 텍스트 | 처음 200자, 3줄 | 전체 표시 |
| 민감 콘텐츠 | 마스킹 `ab••••••yz` | 원문 표시 |
| 이미지 | 썸네일 80px | 300px 확대 |

### 스마트 보안 — 암호화 + 감지

- AES-256-GCM 암호화 (v2), 레거시 AES-CBC+HMAC-SHA256 호환
- 35 규칙의 자동 민감 정보 감지 (비밀번호/API 키/Slack/Discord/OpenAI 토큰/신분증 번호 등)
- 비밀번호 관리자가前台에 있으면 자동 일시 중지, App 내 복사 방지
- 암호화 실패 시 내용 저장 거부, 평문 저장 차단

---

## 기능 목록

- 📋 클립보드 기록 (텍스트/이미지/링크/**Rich Text RTF**)
- ⭐ 중요한 항목 고정, 자동 삭제 방지
- 💾 이미지 암호화 파일 저장, 10MB 제한 돌파
- 🔍 실시간 검색, 전체 언어 하이라이트 지원 (중한일等多바이트 문자)
- ⚡ 스마트 중복 제거, 같은 내용은 타임스탬프만 업데이트
- 🔄 복사 루프 방지, App 내에서 복사 시 자동 건너뛰기
- 🧹 고아 파일 정리, App 실행 시 참조되지 않는 이미지 자동 삭제
- 🌍 7개 언어 (简体中文/繁體中文/English/日本語/한국어/Español/Português)
- ☑️ 다중 선택 일괄 고정/삭제
- ✅ 복사 시 녹색 플래시 피드백
- ⚙️ 첫 실행 시 핫키 충돌 자동 감지
- ⌨️ 글로벌 핫키 `Cmd+Ctrl+V`
- 🖥 로그인 시 실행 (설정에서 활성화)
- 📐 글꼴 크기 (작게/보통/크게)
- 🎨 외형 (라이트/다크/시스템 연동)
- 🗂️ 유형 필터 (전체/텍스트/이미지/링크/Rich Text)
- ⌨️ 키보드 내비게이션 (방향키 스크롤, 검색 상자 포커스 처리)

---

## 사용 방법

| 동작 | 방법 |
|------|------|
| Quick Bar 열기 | 메뉴바 📋 아이콘 클릭 |
| 항목 복사 | 항목 클릭 / 키보드 ↑↓ + Enter |
| 전체 창 열기 | `Cmd+Ctrl+V`(글로벌 단축키) / Quick Bar → "클립보드 열기" |
| 검색 | 키워드 입력, 일치 항목 하이라이트 |
| 고정/해제 | ⭐ 클릭 또는 항목 더블클릭 |
| 삭제 | 🗑 클릭 또는 우클릭 메뉴 |
| 전체/민감/이미지 미리보기 | 0.4s 길게 누르기, 놓으면 원복 |
| 다중 선택 모드 | 체크박스 클릭 |
| 기록 지우기 | 상단 도구 모음 🗑 (고정 항목 유지) |
| 유형 필터 전환 | 사이드바에서 "텍스트/이미지/링크/Rich Text" 클릭 |

> 💡 고정된 항목은 자동 삭제되지 않습니다. 동일한 내용을 다시 복사하면 중복 없이 타임스탬프만 업데이트됩니다.

---

## 보안

- **AES-256-GCM (v2) + 레거시 AES-CBC+HMAC-SHA256** — 모든 텍스트와 이미지를 디스크 저장 전 자동 암호화
- **스마트 감지** — 35 규칙 (키워드 + 정규식)으로 비밀번호, API 키, Slack/Discord/OpenAI 토큰, 개인키, 신분증 번호, 은행카드 번호 등 자동 식별
- **자동 삭제** — 민감 콘텐츠를 1시간/24시간/48시간/7일 후 자동 삭제 또는 삭제 안 함

---

## 설정

- 최대 기록 개수 (50/100/200/500개)
- 민감 정보 자동 삭제 정책 (1시간/24시간/48시간/7일/안 함)
- 언어 전환 (7개 언어)
- 글로벌 핫키 녹음
- 외형 (라이트/다크/시스템 연동)
- 제외 앱 (클립보드 모니터링에서 제외할 앱)
- Rich Text 캡처 토글

---

## 시스템 요구사항

- macOS 13.0 (Ventura) 이상

---

## 데이터 마이그레이션

암호화 키를 포함한 기록은 `~/Library/Application Support/ClipMemory/`에 저장되어 있습니다.
재설치 전에 이 디렉토리를 백업하세요. 같은 Mac 또는 다른 Mac에서 복원하면 계속 기록을 읽을 수 있습니다.
앱을 삭제하기 전에 상단 도구 모음의 🗑 버튼을 클릭하여 기록을 지우는 것이 좋습니다.

---

## 설치

```bash
brew tap irykelee/clipmemory
brew trust irykelee/clipmemory
brew install --cask clipmemory
```

설치 후 App은 `/Applications/ClipMemory.app`에 위치합니다. 실행 후 **화면 오른쪽 상단 메뉴바**의 📋 아이콘을 클릭하여 사용하세요.

또는 [GitHub Releases](https://github.com/irykelee/clipmemory/releases)에서 `.tar.gz`를 다운로드하여 `/Applications/`에 수동 압축 해제.

> **처음 실행할 때 "Apple에서 확인할 수 없음…" 경고가 표시되면**: 공증되지 않은 앱에 대한 macOS의 일반적인 차단이며 악성코드가 아닙니다. ① 앱을 우클릭 → 「열기」 → 다시 「열기」, 또는 ② 시스템 설정 → 개인정보 보호 및 보안 → ClipMemory의 「그래도 열기」. 한 번만 하면 됩니다. (`brew install`로 설치한 경우에는 나타나지 않습니다)

---

## 개발

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

---

## 문의

- GitHub: https://github.com/irykelee/clipmemory
- 피드백: 설정 → 이 Appについて → 피드백 보내기 → GitHub Issues
