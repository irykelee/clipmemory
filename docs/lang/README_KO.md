# ClipMemory v2.5.11

**차세대 macOS 클립보드 관리자 — 원 탭으로 실행, 복사 즉시 검색**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

<p align="center">
  <img src="../screenshots/quick-bar-light-kr.jpg" alt="Quick Bar 팝업 (라이트)" width="360"><br>
  <em>메뉴바에서 Quick Bar 한 번에 실행 — 최근 8개, 즉시 검색·복사 (라이트)</em>
</p>

<p align="center">
  <img src="../screenshots/quick-bar-dark-kr.jpg" alt="Quick Bar 팝업 (다크)" width="360"><br>
  <em>메뉴바에서 Quick Bar 한 번에 실행 — 최근 8개, 즉시 검색·복사 (다크)</em>
</p>

<p align="center">
  <img src="../screenshots/main-window-light-kr.jpg" alt="ClipMemory 메인 창 (라이트)" width="720"><br>
  <em>메인 창: 유형 사이드바 × 시간 그룹 × 검색 강조 (라이트)</em>
</p>

<p align="center">
  <img src="../screenshots/main-window-dark-kr.jpg" alt="ClipMemory 메인 창 (다크)" width="720"><br>
  <em>메인 창: 유형 사이드바 × 시간 그룹 × 검색 강조 (다크)</em>
</p>

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
| **시간 그룹화** | 없음 | 오늘/어제/이전, 접기 가능 |
| **태그** | 없음 | 생성 / 삭제 / 사용자 지정 색상, 사이드바 필터 + 스마트 제안 |
| **휴지통** | 삭제 즉시 소멸 | 휴지통에서 복원 가능, 보관 기간 설정 가능 |
| **자동 업데이트** | 수동 다운로드 | 백그라운드 자동 확인, 원클릭 설치 및 재시작 |
| **로컬 백업** | 없음 | 매일 자동 백업 + 암호화 백업 내보내기 / 가져오기 |

---

## 📋 변경 로그

### v2.5.11 (2026-07-23) — ContentView 분할 + 16개 버그 수정

### 주요 업데이트 (Highlights)

- **🏗 ContentView 분할 (NEW-7 Phase 4)** — 기본 목록 / 선택 / 일괄 작업 / 삭제 알림을 모두 ContentView에서 독립적인 `ItemListView`(287줄)로 추출; ContentView 1178 → 995줄(-15.5%). list render + list-related state 분리, 그러나 view 계층의 검색 / filter / 스크롤 캐시는 ContentView에 유지(일회성 리팩터 위험 방지). 이후 Phase 6+ ViewModel collapse에서 `@State`를 `@StateObject`로 수렴하면 ItemListView snapshot baseline 개설 가능
- **🛡 데이터 안전 4종 세트** — `maxItems` setter clamp 1...10_000으로 음수/초과 방지; `backupNow()` 직렬화(NSLock)로 double-click + auto-backup 경합 방지; `addTag()` 앞/뒤 공백 제거로 "  Work  "와 "Work" 중복 저장 방지; `ClipboardItemRow`가 LanguageManager를 observe하여 언어 전환 시 날짜 즉시 재렌더링
- **🌐 i18n 복수형 지원 (F-7)** — 6개의 %d 복수형 키가 `.stringsdict`로 처리됨(batch.selected / quickbar.recent / trash.emptyConfirm.message / alert.clear.message / settings.max.items.count / clear.conditional.confirm); 영어 "1 item" / "5 items"가 더 이상 모두 "1 items"로 표시되지 않음; `Scripts/generate_stringsdict.py` 추가로 7개 언어 일괄 재생성
- **🛡 설정 "Back Up Now" 오류 더 이상 조용히 무시되지 않음 (F-4)** — 기존 `try?`가 모든 backupNow() 실패를 직접 폐기; 이제 do/catch + onShowBackupError callback → ContentView에서 `L10n.settingsBackupError` NSAlert 표시(export/import/pre-import snapshot 실패 경로와 일관성 유지)
- **🛡 QuickBar ⌘F가 실제로 검색에 포커스됨 (F-9)** — 이전에는 KeyCaptureView의 NSEvent local monitor에만 의존(popover 창 컨텍스트에서 불안정); 이제 `.cmdFFindAction` notification을 추가하여 ContentView와 동일한 경로로 작동

### 수정 사항 (Fixes)

영향 순서 (높음 → 중간 → 낮음):

**높은 영향 (아키텍처 / 데이터 / UX 중요 경로)**

- **NEW-7 Phase 4 ItemListView 추출** — 기본 목록 / 선택 / 일괄 작업 / 삭제 알림을 모두 ContentView에서 추출(287줄); ContentView 1178 → 995줄(-15.5%)
- **E-1 maxItems setter clamp** — `1...10_000` 범위 내; UserDefaults가 더 이상 -1 / 999_999_999로 오염되지 않음; 새로운 `minMaxItems` / `maxMaxItems` 상수가 유일한 source of truth
- **E-2 backupNow() 직렬화** — `NSLock`으로 감쌈; double-click "Back Up Now" + auto-backup 동시 프레임 트리거 시 `createDirectory` + `copyItem(Images)` 경합 방지
- **E-13 ClipboardItemRow observe LanguageManager** — `@ObservedObject private var languageManager = LanguageManager.shared`; 설정 → 언어 전환 시 날짜 형식 즉시 재렌더링(더 이상 스크롤 off+on 대기 불필요)
- **F-9 QuickBar ⌘F 수정** — `.onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction))`를 QuickBarView 루트 VStack에 추가; popover 환경에서도 ⌘F로 search field 포커스 가능
- **F-4 설정 Back Up Now 오류 alert** — `onShowBackupError` callback이 ContentView의 `showBackupInfo(L10n.settingsBackupError)`에 연결; 실패 시 이제 표시됨

**중간 영향 (UX 일관성 / a11y / i18n)**

- **F-10 Welcome Enter 기본 버튼 바인딩** — `.keyboardShortcut(.defaultAction)`을 `getStartedButton`에 추가; Welcome 팝업에서 Enter 키로 바로 onComplete 실행
- **F-13 TipsView ↑↓ 레이블** — `L10n.quickbarRecent(8)`을 `L10n.tipsKeyUpdown` = "Navigate items"로 변경; 6개 언어 모두 네이티브 번역(zh-Hans 切换条目 / zh-Hant 切換條目 / ja 項目を移動 / ko 항목 이동 / es Navegar por los elementos / pt Navegar pelos itens)
- **F-3 TrashItemRow 버튼 키보드 가시성** — `@FocusState private var isFocused: Bool` + `.focusable()` + `.focused($isFocused)`; row 포커스 상태에서 opacity로 버튼 표시(이전에는 hover에서만 표시)
- **F-16 TagPickerSheet 키보드 삭제** — `.contextMenu` + `.onDeleteCommand`; ⌫ / Forward Delete 키 또는 오른쪽 클릭 메뉴로 삭제 확인 가능(이전에는 long-press만 가능)
- **F-20 pin/delete accessibilityLabel** — Image-only Button에 `.accessibilityLabel(...)` 추가, 기존 `L10n.tooltip*` 키 재사용; VoiceOver가 더 이상 "button"이라는 컨텍스트 없는 레이블을 읽지 않음

**낮은 영향 (정리 / 성능 / 경계 정확성 / i18n 개선)**

- **E-6 addTag 공백 제거** — `tag.name.trimmingCharacters(in: .whitespacesAndNewlines)`를 `addTag(_:)` 진입점에 추가; "  Work  "와 "Work"가 더 이상 중복 저장되지 않음
- **BUG-007 ItemListView header toggle 검색 중 건너뛰기** — `onTapGesture`가 `!searchText.isEmpty`일 때 no-op; force-expand 표시 규칙에서 collapsedGroups를 변경하면 검색 시 예상치 못한 collapsed 상태가 나타나는 문제 해결
- **F-25 UpdateStatusPanelView DateFormatter 캐시** — `static let dateFormatter`; body 재렌더링 시마다 새로운 DateFormatter를 생성하지 않음
- **F-7 .stringsdict 3개 복수형 키 확장** — `alert.clear.message` / `settings.max.items.count` / `clear.conditional.confirm`; 3개의 다중 인수 키(alert.trim 2x %d / tagPicker & sidebar.deleteTag with %@)는 다음 라운드로 연기

### 업그레이드 안내 (Upgrade Note)

- v2.4.0부터 자동 업데이트 모듈(Sparkle)이 포함된 버전: 앱 내 자동 업데이트를 기다리거나 `brew upgrade --cask clipmemory` 실행
- 데이터 마이그레이션 없음, 일회성 팝업 없음
- **i18n 개선**: 중국어/일본어/한국어 인터페이스로 전환 시 "Recent 1 item" / "Recent 5 items"가 이제 복수형에 따라 표시됨

### v2.5.11

### 주요 업데이트 (Highlights)

- **🏗 ContentView 분할 (NEW-7 Phase 4)** — 기본 목록 / 선택 / 일괄 작업 / 삭제 알림을 모두 ContentView에서 독립적인 `ItemListView`(287줄)로 추출; ContentView 1178 → 995줄(-15.5%). list render + list-related state 분리, 그러나 view 계층의 검색 / filter / 스크롤 캐시는 ContentView에 유지(일회성 리팩터 위험 방지). 이후 Phase 6+ ViewModel collapse에서 `@State`를 `@StateObject`로 수렴하면 ItemListView snapshot baseline 개설 가능
- **🛡 데이터 안전 4종 세트** — `maxItems` setter clamp 1...10_000으로 음수/초과 방지; `backupNow()` 직렬화(NSLock)로 double-click + auto-backup 경합 방지; `addTag()` 앞/뒤 공백 제거로 "  Work  "와 "Work" 중복 저장 방지; `ClipboardItemRow`가 LanguageManager를 observe하여 언어 전환 시 날짜 즉시 재렌더링
- **🌐 i18n 복수형 지원 (F-7)** — 6개의 %d 복수형 키가 `.stringsdict`로 처리됨(batch.selected / quickbar.recent / trash.emptyConfirm.message / alert.clear.message / settings.max.items.count / clear.conditional.confirm); 영어 "1 item" / "5 items"가 더 이상 모두 "1 items"로 표시되지 않음; `Scripts/generate_stringsdict.py` 추가로 7개 언어 일괄 재생성
- **🛡 설정 "Back Up Now" 오류 더 이상 조용히 무시되지 않음 (F-4)** — 기존 `try?`가 모든 backupNow() 실패를 직접 폐기; 이제 do/catch + onShowBackupError callback → ContentView에서 `L10n.settingsBackupError` NSAlert 표시(export/import/pre-import snapshot 실패 경로와 일관성 유지)
- **🛡 QuickBar ⌘F가 실제로 검색에 포커스됨 (F-9)** — 이전에는 KeyCaptureView의 NSEvent local monitor에만 의존(popover 창 컨텍스트에서 불안정); 이제 `.cmdFFindAction` notification을 추가하여 ContentView와 동일한 경로로 작동

### 수정 사항 (Fixes)

영향 순서 (높음 → 중간 → 낮음):

**높은 영향 (아키텍처 / 데이터 / UX 중요 경로)**

- **NEW-7 Phase 4 ItemListView 추출** — 기본 목록 / 선택 / 일괄 작업 / 삭제 알림을 모두 ContentView에서 추출(287줄); ContentView 1178 → 995줄(-15.5%)
- **E-1 maxItems setter clamp** — `1...10_000` 범위 내; UserDefaults가 더 이상 -1 / 999_999_999로 오염되지 않음; 새로운 `minMaxItems` / `maxMaxItems` 상수가 유일한 source of truth
- **E-2 backupNow() 직렬화** — `NSLock`으로 감쌈; double-click "Back Up Now" + auto-backup 동시 프레임 트리거 시 `createDirectory` + `copyItem(Images)` 경합 방지
- **E-13 ClipboardItemRow observe LanguageManager** — `@ObservedObject private var languageManager = LanguageManager.shared`; 설정 → 언어 전환 시 날짜 형식 즉시 재렌더링(더 이상 스크롤 off+on 대기 불필요)
- **F-9 QuickBar ⌘F 수정** — `.onReceive(NotificationCenter.default.publisher(for: .cmdFFindAction))`를 QuickBarView 루트 VStack에 추가; popover 환경에서도 ⌘F로 search field 포커스 가능
- **F-4 설정 Back Up Now 오류 alert** — `onShowBackupError` callback이 ContentView의 `showBackupInfo(L10n.settingsBackupError)`에 연결; 실패 시 이제 표시됨

**중간 영향 (UX 일관성 / a11y / i18n)**

- **F-10 Welcome Enter 기본 버튼 바인딩** — `.keyboardShortcut(.defaultAction)`을 `getStartedButton`에 추가; Welcome 팝업에서 Enter 키로 바로 onComplete 실행
- **F-13 TipsView ↑↓ 레이블** — `L10n.quickbarRecent(8)`을 `L10n.tipsKeyUpdown` = "Navigate items"로 변경; 6개 언어 모두 네이티브 번역(zh-Hans 切换条目 / zh-Hant 切換條目 / ja 項目を移動 / ko 항목 이동 / es Navegar por los elementos / pt Navegar pelos itens)
- **F-3 TrashItemRow 버튼 키보드 가시성** — `@FocusState private var isFocused: Bool` + `.focusable()` + `.focused($isFocused)`; row 포커스 상태에서 opacity로 버튼 표시(이전에는 hover에서만 표시)
- **F-16 TagPickerSheet 키보드 삭제** — `.contextMenu` + `.onDeleteCommand`; ⌫ / Forward Delete 키 또는 오른쪽 클릭 메뉴로 삭제 확인 가능(이전에는 long-press만 가능)
- **F-20 pin/delete accessibilityLabel** — Image-only Button에 `.accessibilityLabel(...)` 추가, 기존 `L10n.tooltip*` 키 재사용; VoiceOver가 더 이상 "button"이라는 컨텍스트 없는 레이블을 읽지 않음

**낮은 영향 (정리 / 성능 / 경계 정확성 / i18n 개선)**

- **E-6 addTag 공백 제거** — `tag.name.trimmingCharacters(in: .whitespacesAndNewlines)`를 `addTag(_:)` 진입점에 추가; "  Work  "와 "Work"가 더 이상 중복 저장되지 않음
- **BUG-007 ItemListView header toggle 검색 중 건너뛰기** — `onTapGesture`가 `!searchText.isEmpty`일 때 no-op; force-expand 표시 규칙에서 collapsedGroups를 변경하면 검색 시 예상치 못한 collapsed 상태가 나타나는 문제 해결
- **F-25 UpdateStatusPanelView DateFormatter 캐시** — `static let dateFormatter`; body 재렌더링 시마다 새로운 DateFormatter를 생성하지 않음
- **F-7 .stringsdict 3개 복수형 키 확장** — `alert.clear.message` / `settings.max.items.count` / `clear.conditional.confirm`; 3개의 다중 인수 키(alert.trim 2x %d / tagPicker & sidebar.deleteTag with %@)는 다음 라운드로 연기

### 업그레이드 안내 (Upgrade Note)

- v2.4.0부터 자동 업데이트 모듈(Sparkle)이 포함된 버전: 앱 내 자동 업데이트를 기다리거나 `brew upgrade --cask clipmemory` 실행
- 데이터 마이그레이션 없음, 일회성 팝업 없음
- **i18n 개선**: 중국어/일본어/한국어 인터페이스로 전환 시 "Recent 1 item" / "Recent 5 items"가 이제 복수형에 따라 표시됨

### v2.5.10 (2026-07-22) — 백업 오류 노출 + UI 리팩터 + SwiftUI 경고 수정

- **🛡 백업 손상 노출（BUG-024）** — 손상된 items.json / trash.json / tags.json / 이미지 파일이 조용히 0개 항목을 가져오지 않음; 실패 시 `corruptedData` throw하고 설정 화면에서 알림 표시
- **⚡ SidebarView 추출（NEW-7 Phase 3）** — ContentView 1162줄에서 1123줄로 축소; 사이드바는 독립적인 11 매개변수 명시적 인터페이스, 단위 테스트 + 수동 검증 7/7 통과
- **🛡 SwiftUI @State 경고 수정（BUG-009）** — `ClipboardItemRow` 하이라이트 캐시를 `@State` 딕셔너리에서 `NSCache`로 이전; "Modifying state during view update" 런타임 경고 해소, 캐시 한도 countLimit=500으로 메모리 누수 방지

### v2.5.9 (2026-07-21) — 행 감지 + 전체 감사 수정

- **🛡 행 감지（HangDetector）** — 메인 스레드 하트비트 + 30초 프로브; 60초 무응답을 처음 감지하면 스택을 기록하고 자동 복구; UI 정지의 침묵 방지
- **🛡 백업 PBKDF2 업그레이드** — 단일 라운드 HKDF를 600k 라운드 PBKDF2-SHA256으로 대체; 오프라인 무차별 대입 비용 ~10⁵× 증가(OWASP 2023 준수); 이전 패키지 투명 호환
- **⚡ RTF 복사 캐시 브리지** — `copyToClipboard` RTF 분기가 캐시 히트 시 < 1ms(이전엔 매번 20-100ms 동기 파싱으로 메인 스레드 블로킹); list / quickbar 간 캐시 자동 브리지
- **🛡 UI 상태 보존** — 검색바 입력이 `@State didSet`의 Binding 우회로 키보드 하이라이트를 남기지 않음; 사이드바 태그 배지가 태그 증감으로 stale 되지 않음
- **🛡 메인 스레드 I/O 오프로드** — `copyToClipboard` image / RTF 경로가 클립보드 폴링을 블로킹하지 않음; 백업 익스포트 50MB 크기 가드로 OOM 방지

### v2.5.8 (2026-07-20) — 안정성 감사 + 23개 수정

- **🛡 백업 내보내기/가져오기 강화** — 멈춘 `ditto`가 더 이상 UI를 무한 차단하지 않음 (30s 타임아웃 + SIGKILL 에스컬레이션); HKDF 솔트가 OS CSPRNG 실패 시 명시적 오류, 0 채움의 침묵 사용 중단
- **⚡ RTF 파싱을 백그라운드 큐로 이동** — 대용량 리치 텍스트 붙여넣기가 더 이상 클립보드 폴링을 停滞시키지 않음; OCR/이미지 인식도 백그라운드, 메인 스레드 매끄럽게
- **🛡 SwiftUI 렌더링 경고 수정** — 아이템 수 변경 시 "Modifying state during view update" 경고 제거, 불필요한 추가 렌더링 없음
- **🔧 메모리 저장소 스레드 안전** — 테스트와 미래 멀티스레드 호출자가 `MemoryStorageBackend` 배열 변경으로 더 이상 크래시/데이터 손실 없음
- **🏷 태그 색상 폴백 수정** — 잘못된 hex 색상이 강조 색으로 폴백, 라이트/다크 모드 모두에서 보임

### v2.5.7 (2026-07-20) — HangDetector 감시 + 주요 버그 수정

- **🛰️ HangDetector 관측 모듈** — 백그라운드 watchdog가 메인 스레드 60초 이상 행(Hang)을 자동 감지, 콜스택 전체와 복구 시각 기록. 사후 디버깅에 유용
- **🛡️ HMAC 실패 시 묵시적 데이터 손실 수정** — 드문 Keychain 액세스 오류 시 복사 내용이 중복으로 폐기되던 문제 해결
- **🛡️ QuickBar 키보드 네비게이션 크래시 수정** — 선택 항목이 외부에서 삭제된 후 ↑↓ 입력 시 OOB 크래시 발생 안 함
- **🧪 테스트 force-unwrap 크래시 수정** — `XCTAssertNotNil + !` 패턴을 `guard let ... XCTFail(...) return`로 대체
- **🖼️ 이미지 로드 동시성 경쟁 수정** — 레거시 이미지 마이그레이션의 다중 스레드 동시 쓰기를 직렬화하여 경쟁 회피
- **🛡️ Excluded-app 설정 TOCTOU 수정** — 원자적 `updateExcludedBundleIds` API 추가
- **🧹 메인 윈도우 일괄 선택 툴바 상태 잔류 수정** — 행 삭제 후 툴바가 올바르게 사라짐

### v2.5.6 (2026-07-19) — 키체인 이전 + 원본 미리보기 + 시작 강화

- **🔐 키를 키체인으로 이전** — 암호화 루트 키를 평문 파일에서 macOS 키체인으로(이 기기 전용, iCloud 동기화 없음). brew 제거(zap) 시 함께 삭제됩니다
- **🖼 이미지 원본 미리보기** — 길게 누르면 원본 크기 플로팅 패널 표시. 큰 스크린샷은 스크롤로 볼 수 있어 글자가 선명합니다(300px 행내 확대 대체)
- **🛡 시작 강화** — 키 손상이나 저장 실패 시 더 이상 강제 종료되지 않고, 종료/재시도/재설정(기록 삭제)을 고르는 명확한 알림 표시
- **🌐 미러는 확인 후 사용** — GitHub 업데이트 서버에 연결할 수 없을 때 jsDelivr 미러 전환 전 한 번 확인하고 선택을 기억. 오래된 미러는 자동 거부

### v2.5.5 (2026-07-18) — 조건별 삭제 + 안정성 강화

- **🗑 조건별 삭제** — 도구 모음 🗑 에「조건별 삭제」추가: 유형 × 기간 조합(예: 오늘 이전 이미지만 삭제하고 오늘 것은 유지). 텍스트/이미지/링크/서식 탭 우클릭으로 해당 유형 전체 삭제. 각 시간 그룹 헤더에 삭제 버튼 추가
- **🏷️ 태그 삭제 옵션** — 태그 삭제 시「태그만 삭제」또는「태그와 내용을 휴지통으로」선택 가능
- **🔧 가져오기 강화** — 다른 Mac에서 가져올 때 태그 이름이 올바르게 복호화됨(깨짐 해소). 같은 패키지 내 중복 가져오기, 복호화 실패 항목의 잘못된 가져오기, 큰 패키지에서의 UI 멈춤, 백업 정리가 외부 파일을 지우던 문제 수정

### v2.5.0 (2026-07-18) — 로컬 백업 + 내보내기/가져오기

- **💾 로컬 자동 백업** — 매일 첫 실행 시 클립보드 기록(태그, 휴지통, 이미지 포함)을 로컬 Backups 폴더에 자동 백업. 기본 7개 보관(3/7/14/30 선택 가능), 데이터 유실 방지
- **📦 백업 내보내기 / 가져오기** — 한 번의 클릭으로 .clipmemory 암호화 백업(암호 보호) 내보내기. 새 Mac으로 옮기거나 재설치 후 가져오면 복원 완료. 가져오기는 기존 데이터와 병합·중복 제거하며 덮어쓰지 않음
- **⚙️ 설정에 「백업」 추가** — 자동 백업 스위치, 보관 수, 지금 백업, 백업 폴더 열기, 내보내기/가져오기

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
| 이미지 | 썸네일 80px | 원본 크기 플로팅 패널(화면 초과 시 스크롤) |

### 스마트 보안 — 암호화 + 감지

- AES-256-GCM 암호화 (v2), 레거시 AES-CBC+HMAC-SHA256 호환
- 35 규칙의 자동 민감 정보 감지 (비밀번호/API 키/Slack/Discord/OpenAI 토큰/신분증 번호 등)
- 비밀번호 관리자가前台에 있으면 자동 일시 중지, App 내 복사 방지
- 암호화 실패 시 내용 저장 거부, 평문 저장 차단

---

## 기능 목록

- 📋 클립보드 기록 (텍스트/이미지/링크/**Rich Text RTF**)
- ⭐ 중요한 항목 고정, 자동 삭제 방지
- 💾 이미지 암호화 파일 저장, 이미지당 최대 50MB
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
| 조건별 삭제 | 상단 도구 모음 🗑 →「조건별 삭제」(유형 × 기간). 유형 탭 우클릭으로 해당 유형 전체 삭제 |
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
- 글꼴 크기 (소 / 중 / 대)
- 로그인 시 실행
- 휴지통 보관 기간 (3 / 7 / 14 / 30일)
- 백업 (매일 자동 / 보관 수 / 내보내기 / 가져오기)
- 자동 업데이트 (자동 확인 / 지금 확인)

---

## 시스템 요구사항

- macOS 13.0 (Ventura) 이상

---

## 데이터 마이그레이션

암호화 키를 포함한 기록은 `~/Library/Application Support/ClipMemory/`에 저장되어 있습니다.
설정 → 백업 → 백업 내보내기로 .clipmemory 암호화 패키지를 만들어 새 Mac에서 가져오는 방법을 권장합니다. 이 디렉토리를 직접 백업해 수동으로 옮길 수도 있습니다.
앱을 삭제하기 전에 상단 도구 모음의 🗑 버튼으로 기록을 지울 수 있습니다.

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
