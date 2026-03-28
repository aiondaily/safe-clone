#!/usr/bin/env bash
# ============================================================================
# safe-clone.sh — 隔離式 Repo 安全掃描
#
# 流程：
#   1. GitHub API 預檢（元資料風險評估）
#   2. Docker 容器內 git clone（hooks disabled）
#   3. Docker 容器內完整安全掃描
#   4. 報告匯出到 host
#   5. 容器自動銷毀
#
# 用法：
#   ./safe-clone.sh <github_repo_url>
#   ./safe-clone.sh https://github.com/someone/cool-project
#   ./safe-clone.sh --build    # 僅建置 Docker image
#   ./safe-clone.sh --no-preflight <url>  # 跳過 API 預檢
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="repo-security-scanner"
IMAGE_TAG="latest"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

# ─── 顏色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}── $* ──${NC}"; }

# ─── 使用說明 ─────────────────────────────────────────────────────────────────
usage() {
    echo "用法: $0 [選項] <github_repo_url>"
    echo ""
    echo "選項:"
    echo "  --build          僅建置/更新 Docker image"
    echo "  --no-preflight   跳過 GitHub API 預檢"
    echo "  --force          即使預檢不通過也繼續掃描"
    echo "  --keep           掃描後保留容器（除錯用）"
    echo "  -h, --help       顯示此說明"
    echo ""
    echo "範例:"
    echo "  $0 https://github.com/someone/cool-project"
    echo "  $0 --no-preflight https://github.com/someone/cool-project"
    exit 1
}

# ─── 參數解析 ─────────────────────────────────────────────────────────────────
REPO_URL=""
BUILD_ONLY=false
SKIP_PREFLIGHT=false
FORCE=false
KEEP_CONTAINER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)         BUILD_ONLY=true; shift ;;
        --no-preflight)  SKIP_PREFLIGHT=true; shift ;;
        --force)         FORCE=true; shift ;;
        --keep)          KEEP_CONTAINER=true; shift ;;
        -h|--help)       usage ;;
        -*)              error "未知選項: $1"; usage ;;
        *)               REPO_URL="$1"; shift ;;
    esac
done

# ─── Docker image 建置 ───────────────────────────────────────────────────────
build_image() {
    header "建置 Docker 掃描映像"

    if docker image inspect "$FULL_IMAGE" &>/dev/null && [[ "$BUILD_ONLY" == false ]]; then
        info "映像 $FULL_IMAGE 已存在，跳過建置（用 --build 強制重建）"
        return 0
    fi

    info "建置 $FULL_IMAGE ..."
    docker build -t "$FULL_IMAGE" "$SCRIPT_DIR"
    success "映像建置完成"
}

# ─── GitHub API 預檢 ─────────────────────────────────────────────────────────
preflight_check() {
    header "Step 1：GitHub API 預檢"

    # 從 URL 提取 owner/repo
    local owner repo api_url
    if [[ "$REPO_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
    else
        warn "非 GitHub URL，跳過預檢"
        return 0
    fi

    api_url="https://api.github.com/repos/${owner}/${repo}"
    info "查詢 ${owner}/${repo} ..."

    local response
    local curl_opts=(-sSf --max-time 10)
    # 如果有 GITHUB_TOKEN 就用，避免 rate limit
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl_opts+=(-H "Authorization: token ${GITHUB_TOKEN}")
    fi

    if ! response=$(curl "${curl_opts[@]}" "$api_url" 2>/dev/null); then
        warn "無法取得 API 資料（可能 rate limited 或 repo 不存在），跳過預檢"
        return 0
    fi

    # 解析元資料
    local stars forks age_days created_at pushed_at is_fork archived description owner_type
    stars=$(echo "$response" | jq -r '.stargazers_count // 0')
    forks=$(echo "$response" | jq -r '.forks_count // 0')
    created_at=$(echo "$response" | jq -r '.created_at // ""')
    pushed_at=$(echo "$response" | jq -r '.pushed_at // ""')
    is_fork=$(echo "$response" | jq -r '.fork // false')
    archived=$(echo "$response" | jq -r '.archived // false')
    description=$(echo "$response" | jq -r '.description // "(無)"')
    owner_type=$(echo "$response" | jq -r '.owner.type // "Unknown"')

    # 計算 repo 年齡（天）
    if [[ -n "$created_at" ]]; then
        local created_epoch now_epoch
        if date --version &>/dev/null 2>&1; then
            created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
        else
            created_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || echo 0)
        fi
        now_epoch=$(date +%s)
        age_days=$(( (now_epoch - created_epoch) / 86400 ))
    else
        age_days=0
    fi

    # 風險評分
    local risk_score=0
    local risk_flags=()

    echo ""
    echo -e "  ${BOLD}Repo:${NC}        ${owner}/${repo}"
    echo -e "  ${BOLD}說明:${NC}        ${description}"
    echo -e "  ${BOLD}Owner 類型:${NC}  ${owner_type}"
    echo -e "  ${BOLD}Stars:${NC}       ${stars}"
    echo -e "  ${BOLD}Forks:${NC}       ${forks}"
    echo -e "  ${BOLD}年齡:${NC}        ${age_days} 天"
    echo -e "  ${BOLD}Is Fork:${NC}     ${is_fork}"
    echo -e "  ${BOLD}Archived:${NC}    ${archived}"
    echo ""

    # 風險評估規則
    if [[ "$stars" -lt 10 ]]; then
        risk_score=$((risk_score + 3))
        risk_flags+=("Stars < 10（低知名度）")
    elif [[ "$stars" -lt 50 ]]; then
        risk_score=$((risk_score + 1))
        risk_flags+=("Stars < 50（知名度偏低）")
    fi

    if [[ "$age_days" -lt 30 ]]; then
        risk_score=$((risk_score + 3))
        risk_flags+=("Repo 年齡 < 30 天（非常新）")
    elif [[ "$age_days" -lt 90 ]]; then
        risk_score=$((risk_score + 1))
        risk_flags+=("Repo 年齡 < 90 天（較新）")
    fi

    if [[ "$is_fork" == "true" ]]; then
        risk_score=$((risk_score + 1))
        risk_flags+=("是 Fork（可能被修改植入惡意程式碼）")
    fi

    if [[ "$owner_type" == "User" ]] && [[ "$stars" -lt 5 ]]; then
        risk_score=$((risk_score + 2))
        risk_flags+=("個人帳號 + 極低 stars")
    fi

    # 檢查 owner 的其他 repo 數量
    local owner_repos
    owner_repos=$(echo "$response" | jq -r '.owner.public_repos // 0' 2>/dev/null || echo 0)
    # owner.public_repos 不一定在 repo API 回來，改查 owner
    if [[ "$owner_repos" -eq 0 ]]; then
        local owner_api
        if ! owner_api=$(curl "${curl_opts[@]}" "https://api.github.com/users/${owner}" 2>/dev/null); then
            owner_repos="?"
        else
            owner_repos=$(echo "$owner_api" | jq -r '.public_repos // 0')
        fi
    fi
    if [[ "$owner_repos" != "?" ]] && [[ "$owner_repos" -lt 3 ]]; then
        risk_score=$((risk_score + 2))
        risk_flags+=("Owner 僅有 ${owner_repos} 個 public repo")
    fi

    # 輸出風險評估
    echo -e "  ${BOLD}風險評分:${NC} ${risk_score}/10"
    if [[ ${#risk_flags[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}風險因素:${NC}"
        for flag in "${risk_flags[@]}"; do
            echo -e "    ${YELLOW}•${NC} $flag"
        done
    fi
    echo ""

    # 判定
    if [[ "$risk_score" -ge 5 ]]; then
        error "高風險 repo（評分 ${risk_score}/10）"
        if [[ "$FORCE" == true ]]; then
            warn "--force 指定，繼續執行掃描..."
        else
            error "建議加上 --force 強制掃描，或確認此 repo 來源可信"
            exit 1
        fi
    elif [[ "$risk_score" -ge 3 ]]; then
        warn "中等風險（評分 ${risk_score}/10），將在 Docker 隔離環境中掃描"
    else
        success "低風險（評分 ${risk_score}/10）"
    fi
}

# ─── Docker 隔離掃描 ─────────────────────────────────────────────────────────
run_scan_in_docker() {
    header "Step 2：Docker 隔離掃描"

    local repo_name timestamp report_host_dir container_name
    repo_name=$(basename "$REPO_URL" .git)
    timestamp=$(date +%Y%m%d_%H%M%S)
    report_host_dir="${SCRIPT_DIR}/scan_reports/${repo_name}_${timestamp}"
    container_name="repo-scan-${repo_name}-${timestamp}"

    mkdir -p "$report_host_dir"

    info "容器名稱: ${container_name}"
    info "報告目錄: ${report_host_dir}"
    info "開始隔離掃描..."
    echo ""

    # 安全限制：
    #   --cap-drop=ALL 移除所有特權
    #   --security-opt=no-new-privileges 防止提權
    #   --memory / --cpus 限制資源
    #   trivy-cache volume 持久化 Trivy DB（避免每次下載 ~88MB）
    local docker_opts=(
        --name "$container_name"
        --cap-drop=ALL
        --security-opt=no-new-privileges
        --memory=2g
        --cpus=2
        --pids-limit=256
        --tmpfs /tmp:rw,noexec,nosuid,size=1g
        --tmpfs /workspace:rw,noexec,nosuid,size=2g
        -v "${report_host_dir}:/output:rw"
        -v "trivy-db-cache:/root/.cache/trivy"
        -e "REPORT_OUTPUT_DIR=/output"
    )

    if [[ "$KEEP_CONTAINER" == false ]]; then
        docker_opts+=(--rm)
    fi

    # 執行掃描（-d 先啟動，印出容器資訊，再 attach 等結果）
    local container_id
    container_id=$(docker run -d "${docker_opts[@]}" "$FULL_IMAGE" "$REPO_URL")
    info "Docker 容器已啟動"
    info "  Container ID: ${container_id:0:12}"
    info "  Image:        $FULL_IMAGE"
    info "  驗證指令:     docker inspect ${container_id:0:12} (掃描期間可執行)"
    echo ""

    # attach 等待容器結束並輸出 log
    local exit_code=0
    docker logs -f "$container_id" || true
    exit_code=$(docker inspect "$container_id" --format='{{.State.ExitCode}}' 2>/dev/null || echo 1)
    # 手動清理（因為 -d 模式下 --rm 行為不同）
    docker rm -f "$container_id" >/dev/null 2>&1 || true

    echo ""
    if [[ "$exit_code" -eq 0 ]]; then
        success "掃描完成"
    else
        warn "掃描完成（部分工具可能有 warning，exit code: ${exit_code}）"
    fi

    # 顯示報告
    header "Step 3：掃描報告"

    if [[ -f "${report_host_dir}/FINAL_REPORT.md" ]]; then
        echo ""
        cat "${report_host_dir}/FINAL_REPORT.md"
        echo ""
        success "完整報告目錄: ${report_host_dir}"
        echo -e "  ${DIM}ls -la ${report_host_dir}/${NC}"
    else
        warn "未找到最終報告，請檢查掃描 log"
        echo "報告目錄: ${report_host_dir}"
        ls -la "${report_host_dir}/" 2>/dev/null || true
    fi
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║   🔒 Safe Clone — 隔離式 Repo 安全掃描   ║"
    echo "  ║   Docker 沙箱 + GitHub API 預檢          ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    # 檢查 Docker
    if ! command -v docker &>/dev/null; then
        error "Docker 未安裝，請先安裝 Docker"
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        error "Docker daemon 未運行，請先啟動 Docker"
        exit 1
    fi

    # 僅建置
    if [[ "$BUILD_ONLY" == true ]]; then
        build_image
        exit 0
    fi

    # 需要 URL
    if [[ -z "$REPO_URL" ]]; then
        usage
    fi

    # 建置 image（如果不存在）
    build_image

    # 預檢
    if [[ "$SKIP_PREFLIGHT" == false ]]; then
        preflight_check
    fi

    # Docker 隔離掃描
    run_scan_in_docker
}

main
