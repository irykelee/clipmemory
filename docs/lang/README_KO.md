<details>
<summary><b>🌐 Languages / 언어</b></summary>

| Language | Link |
|----------|------|
| English | [README_EN.md](./README_EN.md) |
| 简体中文 | [README.md](../README.md) |
| 日本語 | [README_JA.md](./README_JA.md) |
| 한국어 | [README_KO.md](./README_KO.md) |
| Español | [README_ES.md](./README_ES.md) |
| Português | [README_PT.md](./README_PT.md) |

---
</details>

---

# ClipMemory 클립모리 (한국어)

**로컬 클립보드 히스토리 관리자**

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
| 창 호출 | `⌘⇧V` |
| 이동 | `↑` / `↓` 키 |
| 복사 | `Enter` |
| 닫기 | `Esc` |
| 검색 | 키워드 입력으로 실시간 필터링 |
| 고정 | ⭐ 클릭 또는 우클릭→「고정」 |
| 삭제 | 🗑 클릭 또는 우클릭→「삭제」 |

## 설정

- 최대 히스토리 수 (50/100/200/500/1000/2000)
- 민감정보 자동 삭제 정책 (1시간/24시간/48시간/7일/안함)
- 언어 전환

## 필요 환경

- macOS 13.0 (Ventura) 이상

## 설치

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

## 개발

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

## 연락처

- GitHub: https://github.com/irykelee/clipmemory
