# agent-candy

Claude Code 플러그인 마켓플레이스. `candy` 플러그인 하나를 제공한다.

## candy — 5시간 윈도우 자동화

점심시간을 Claude Code 의 5시간 사용 윈도우 안에 포함시켜 토큰 낭비를 줄이고, 오후 고사용 시간대에 새 윈도우가 시작되도록 자동 조정하는 macOS LaunchAgent 번들이다.

자세한 내부 동작은 [plugins/candy/README.md](plugins/candy/README.md) 를 참고.

## 설치

### 1. 이 마켓플레이스 등록

Claude Code 에서:

```
/plugin marketplace add nonsignal007/agent-candy
```

### 2. 플러그인 설치

```
/plugin install candy@agent-candy
```

### 3. 설치 스킬 실행

플러그인이 설치되면 `candy-setup` 스킬이 자동 등록된다. 설치하려면 다음과 같이 요청한다:

- "claude candy 설치해줘"
- "candy 스케줄러 설정"
- "점심시간 pre-warm 설정"

스킬이 다음을 자동으로 수행한다:

1. JOBS_ROOT 경로 확인 (기본 `~/jobs`)
2. 의존성 검증 (`claude`, `python3`, `launchctl`, `plutil`, `osascript`)
3. Claude CLI preflight
4. 플러그인 번들을 JOBS_ROOT 로 복사
5. `~/Library/LaunchAgents` symlink 생성
6. LaunchAgent 부트스트랩
7. **macOS 알림 권한 확인 (사용자 수동 단계)**
8. `launchctl print` 로 검증
9. 가상 회귀 테스트 실행
10. (옵션) Live smoke 테스트

## 요구 사항

- macOS (GUI 로그인 세션)
- `claude` CLI (로그인된 상태)
- `python3`, `launchctl`, `plutil`, `osascript`

## 저장소 구조

```
agent-candy/
├── .claude-plugin/
│   └── marketplace.json          # 마켓플레이스 매니페스트
└── plugins/
    └── candy/
        ├── .claude-plugin/
        │   └── plugin.json       # 플러그인 매니페스트
        ├── skills/
        │   └── candy-setup/
        │       └── SKILL.md      # 설치 스킬
        ├── bin/                   # Candy 실행 스크립트
        ├── LaunchAgents/          # plist 템플릿 4개
        ├── config/
        │   └── lunch_schedule.conf
        ├── tests/                 # 가상/실제 테스트
        └── README.md              # Candy 상세 문서
```

## 라이선스

MIT
