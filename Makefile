# Dicto 자동화 Makefile
# 사용법: make <target>

SCHEME       := Dicto
PROJECT      := Dicto.xcodeproj
BUNDLE_ID    := com.lake514.dicto
CONFIG       := Debug
BUILD_DIR    := build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
APP          := $(DERIVED_DATA)/Build/Products/$(CONFIG)/Dicto.app
MODEL_DIR    := $(HOME)/Library/Application Support/Dicto/models
MODEL        := ggml-large-v3-turbo-q5_0.bin
MODEL_URL    := https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$(MODEL)

# 개인 설정(서명 팀 ID 등)은 저장소에 올리지 않는 local.mk에 둔다 (.gitignore)
#   예) DEVELOPMENT_TEAM := ABCDE12345
-include local.mk
TEAM_FLAG    := $(if $(DEVELOPMENT_TEAM),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM))

GREEN := \033[0;32m
YELLOW := \033[0;33m
RESET := \033[0m

.PHONY: help
help: ## 사용 가능한 명령 목록 표시
	@echo "$(GREEN)Dicto Make 명령$(RESET)"
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-12s$(RESET) %s\n", $$1, $$2}'

.PHONY: gen
gen: ## XcodeGen으로 project.yml → xcodeproj 재생성
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

.PHONY: build
build: $(PROJECT) ## 빌드
	@echo "$(GREEN)▶ 빌드 중...$(RESET)"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS' $(TEAM_FLAG) build \
		| grep -E "error:|warning: unre|BUILD|Compiling|Linking" || true
	@test -d $(APP) && echo "$(GREEN)✔ $(APP)$(RESET)"

.PHONY: run
run: kill build ## 빌드 후 실행
	open $(APP)

.PHONY: kill
kill: ## 실행 중인 Dicto 종료
	-pkill -x Dicto 2>/dev/null || true

.PHONY: install
install: build ## /Applications 에 복사
	rm -rf /Applications/Dicto.app
	cp -R $(APP) /Applications/Dicto.app
	xattr -cr /Applications/Dicto.app 2>/dev/null || true
	@echo "$(GREEN)✔ /Applications/Dicto.app$(RESET)"

.PHONY: relaunch
relaunch: ## 실행 중인 Dicto에 재시작 신호 (앱이 스스로 재시작)
	touch "$(HOME)/Library/Application Support/Dicto/.relaunch"
	@echo "$(GREEN)✔ 재시작 신호 보냄$(RESET)"

.PHONY: deploy
deploy: install relaunch ## 빌드 + 설치 + 재시작

.PHONY: model
model: ## whisper 모델 다운로드 (~570MB)
	mkdir -p "$(MODEL_DIR)"
	@test -f "$(MODEL_DIR)/$(MODEL)" && echo "이미 있음" || \
		curl -L --progress-bar -o "$(MODEL_DIR)/$(MODEL)" "$(MODEL_URL)"

.PHONY: setup
setup: ## fn(지구본) 키 단독 입력을 '아무것도 안 함'으로 설정 (이모지/받아쓰기 팝업 방지)
	@echo "현재: $$(defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo '기본값')  (0=아무것도 안 함, 1=입력 소스 변경, 2=이모지, 3=받아쓰기)"
	defaults write com.apple.HIToolbox AppleFnUsageType -int 0
	@echo "$(GREEN)✔ fn 키 → 아무것도 안 함. (적용 안 되면 로그아웃/재로그인)$(RESET)"

.PHONY: sounds
sounds: ## 녹음 시작/끝 효과음 재생성 (코드로 합성)
	python3 scripts/gen_sounds.py

.PHONY: icon
icon: ## 앱 아이콘 재생성 (코드로 그림)
	swift scripts/gen_icon.swift

.PHONY: log
log: ## 앱 로그 보기
	log stream --predicate 'subsystem == "com.lake514.dicto"' --level debug

.PHONY: clean
clean: ## 빌드 산출물 삭제
	rm -rf $(BUILD_DIR)
