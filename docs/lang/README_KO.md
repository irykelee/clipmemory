# ClipMemory v2

**차세대 macOS 클립보드 관리자 — 더 나은 UI, 더 빠른 작업, 더 많은 기능**

[English](../docs/lang/README_EN.md) · [简体中文](../README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## v1 대비 개선 사항

| 항목 | v1 | v2 |
|------|----|----|
| **상호작용** | 메뉴바 클릭 → 메뉴 → 창 열기 | Quick Bar 팝업 (1단계) |
| **메인 화면** | 고정 너비, 사이드바 없음 | **사이드바 네비게이션** |
| **유형 필터** | 가로 버튼 그룹 | 사이드바 세로 목록 |
| **시간 그룹화** | 없음 | 오늘 / 어제 / 이번 주 / 이번 달 / 이전 |
| **길게 누르기** | 없음 | 텍스트→전체, 민감→표시, 이미지→확대 (0.4초) |
| **창 스타일** | 표준 NSWindow | Safari 26 스타일 유리 효과 |
| **글꼴 크기** | 없음 | 작게/보통/크게 3단계 설정 |

## 새로운 기능

- **Quick Bar**: 메뉴바 클릭 → 최근 8개 항목 → 클릭 복사 / 검색
- **길게 누르기**: 0.4초 누르면 텍스트 전체 보기, 민감 내용 표시, 이미지 확대
- **시간 그룹화**: 생성 시간별 자동 그룹화 (접을 수 있음)
- **글꼴 크기 조정**: 설정에서 UI 텍스트 크기 변경
- **단축키 사용자 정의**: 설정에서 글로벌 핫키 녹음

## 설치

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
```

실행 후 **화면 오른쪽 상단 메뉴바**의 📋 아이콘을 클릭하세요. 또는 [GitHub Releases](https://github.com/irykelee/clipmemory/releases)에서 다운로드.

## 시스템 요구사항

macOS 13.0 (Ventura) 이상

## 문의
- 피드백: 설정 → 정보 → GitHub Issues

- GitHub: https://github.com/irykelee/clipmemory
