# ClipMemory 클립모리 (한국어)

**로컬 클립보드 히스토리 관리자**

[English](./README_EN.md) · [简体中文](../README.md) · [Español](./README_ES.md) · [Português](./README_PT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md)

---

## 기능

- 📋 클립보드 히스토리 (텍스트/이미지/링크)
- ⭐ 중요한 스니펫 고정
- 💾 이미지는 파일로 저장 (저장 제한 없음)
- 🔍 빠른 검색
- 🔒 민감정보 보호 (암호화 + 자동 삭제)
- ⌨️ 전역 단축키 `Cmd+Ctrl+V`로 호출
- 🛡️ 로그인 시 시작 (선택)
- 🌍 다국어 지원

## 보안 기능

- **AES-256 암호화** — 비밀번호, API 키 등 민감 콘텐츠는 AES-256으로 암호화
- **안전한 키 관리** — 키는 로컬에 안전하게 저장
- **스마트 감지** — 25+ 민감 데이터 패턴 지원
- **자동 삭제** — 민감 콘텐츠 자동 삭제 시간 설정 가능

## 사용 방법

| 작업 | 방법 |
|------|------|
| 창 호출 | `⌘⇧V` (전역 단축키) |
| 이동 | `↑` / `↓` 키 |
| 복사 | `Enter` 또는 싱글 클릭으로 복사 후 닫기 |
| 닫기 | `Esc` |
| 검색 | 키워드 입력으로 실시간 필터링 |
| 고정/해제 | 더블 클릭으로 전환 |
| 삭제 | 🗑 클릭 또는 컨텍스트 메뉴 |

## 필요 환경

- macOS 13.0 (Ventura) 이상

## 설치

```bash
brew install irykelee/clipmemory/clipmemory
```

## 개발

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

## 연락처

- GitHub: https://github.com/irykelee/clipmemory
