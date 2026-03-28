#!/usr/bin/env bash
# ============================================================================
# repo_security_scan.sh — 自動化 GitHub Repo 安全掃描腳本
# 
# 用法：
#   ./repo_security_scan.sh <repo_url_or_local_path>
#   ./repo_security_scan.sh https://github.com/someone/cool-project
#   ./repo_security_scan.sh ./my-local-repo
#
# 功能：
#   1. Gitleaks   — 掃描 secrets（API keys、passwords、tokens）
#   2. Trivy      — 掃描已知漏洞（CVE）與授權問題
#   3. Bandit     — Python 專案靜態安全分析
#   4. npm audit  — Node.js 專案相依套件漏洞
#   5. pip-audit  — Python 相依套件漏洞
#   6. 自訂規則   — 偵測可疑行為模式（挖礦、反向 shell、混淆等）
#
# 前置需求（腳本會自動檢查並提示安裝）：
#   - gitleaks, trivy, bandit, pip-audit, jq
#
# 輸出：
#   ./scan_reports/<repo_name>_<timestamp>/ 目錄下的完整報告
# ============================================================================

set -euo pipefail

# ─── 顏色定義 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── 輔助函數 ────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[⚠]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; }

# ─── 使用說明 ─────────────────────────────────────────────────────────────────
usage() {
    echo "用法: $0 <repo_url 或 本地路徑>"
    echo ""
    echo "範例:"
    echo "  $0 https://github.com/someone/cool-project"
    echo "  $0 git@github.com:someone/cool-project.git"
    echo "  $0 ./my-local-repo"
    exit 1
}

[[ $# -lt 1 ]] && usage

INPUT="$1"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 退出碼追蹤：0=通過, 1=有風險, 2=工具錯誤
SCAN_EXIT_CODE=0

# ─── 檢查工具是否已安裝 ──────────────────────────────────────────────────────
check_tools() {
    header "步驟 0：檢查掃描工具"

    local missing=()
    local tools=(gitleaks trivy jq)

    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            success "$tool 已安裝 ($(command -v "$tool"))"
        else
            missing+=("$tool")
            warn "$tool 未安裝"
        fi
    done

    # 選擇性工具（依專案語言）
    if command -v bandit &>/dev/null; then
        success "bandit 已安裝（Python 掃描）"
    else
        info "bandit 未安裝 — 將跳過 Python 靜態分析（pip install bandit 可安裝）"
    fi

    if command -v pip-audit &>/dev/null; then
        success "pip-audit 已安裝（Python 相依漏洞）"
    else
        info "pip-audit 未安裝 — 將跳過 Python 相依掃描（pip install pip-audit 可安裝）"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        error "缺少必要工具: ${missing[*]}"
        echo ""
        echo "安裝指引："
        echo "───────────────────────────────────────"
        for m in "${missing[@]}"; do
            case "$m" in
                gitleaks)
                    echo "  gitleaks:"
                    echo "    macOS:  brew install gitleaks"
                    echo "    Linux:  下載 https://github.com/gitleaks/gitleaks/releases"
                    echo "    Docker: docker pull ghcr.io/gitleaks/gitleaks:latest"
                    ;;
                trivy)
                    echo "  trivy:"
                    echo "    macOS:  brew install trivy"
                    echo "    Linux:  sudo apt install trivy 或見 https://github.com/aquasecurity/trivy"
                    echo "    Docker: docker pull aquasec/trivy:latest"
                    ;;
                jq)
                    echo "  jq:"
                    echo "    macOS:  brew install jq"
                    echo "    Linux:  sudo apt install jq"
                    ;;
            esac
        done
        echo "───────────────────────────────────────"
        exit 1
    fi
}

# ─── 取得 Repo ────────────────────────────────────────────────────────────────
prepare_repo() {
    header "步驟 1：準備掃描目標"

    if [[ "$INPUT" == http* ]] || [[ "$INPUT" == git@* ]]; then
        REPO_NAME=$(basename "$INPUT" .git)
        SCAN_DIR="/tmp/repo_scan_${REPO_NAME}_${TIMESTAMP}"
        info "正在 Clone: $INPUT"
        info "目標目錄: $SCAN_DIR"
        # 安全 clone：禁用 git hooks 防止 clone 階段執行惡意程式碼
        git clone --depth 50 \
            --config core.hooksPath=/dev/null \
            --config core.fsmonitor=false \
            "$INPUT" "$SCAN_DIR" 2>&1 | tail -3
        success "Clone 完成（git hooks 已禁用）"
        IS_CLONED=true
    else
        if [[ ! -d "$INPUT" ]]; then
            error "路徑不存在: $INPUT"
            exit 1
        fi
        SCAN_DIR="$(cd "$INPUT" && pwd)"
        REPO_NAME=$(basename "$SCAN_DIR")
        success "使用本地路徑: $SCAN_DIR"
        IS_CLONED=false
    fi

    # 建立報告目錄（Docker 模式下輸出到掛載的 /output）
    if [[ -n "${REPORT_OUTPUT_DIR:-}" ]]; then
        REPORT_DIR="${REPORT_OUTPUT_DIR}"
    else
        REPORT_DIR="./scan_reports/${REPO_NAME}_${TIMESTAMP}"
    fi
    mkdir -p "$REPORT_DIR"
    info "報告目錄: $REPORT_DIR"
}

# ─── 基本資訊蒐集 ─────────────────────────────────────────────────────────────
gather_info() {
    header "步驟 2：蒐集 Repo 基本資訊"

    local info_file="$REPORT_DIR/00_repo_info.txt"
    {
        echo "=== Repo 基本資訊 ==="
        echo "名稱: $REPO_NAME"
        echo "路徑: $SCAN_DIR"
        echo "掃描時間: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        # 檔案統計
        echo "=== 檔案統計 ==="
        echo "總檔案數: $(find "$SCAN_DIR" -type f -not -path '*/.git/*' | wc -l)"
        echo ""
        echo "依副檔名分佈（前 20）:"
        find "$SCAN_DIR" -type f -not -path '*/.git/*' \
            | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
        echo ""

        # 偵測專案語言
        echo "=== 偵測到的專案類型 ==="
        [[ -f "$SCAN_DIR/package.json" ]]       && echo "  ✦ Node.js (package.json)"
        [[ -f "$SCAN_DIR/requirements.txt" ]]   && echo "  ✦ Python (requirements.txt)"
        [[ -f "$SCAN_DIR/setup.py" ]]           && echo "  ✦ Python (setup.py)"
        [[ -f "$SCAN_DIR/pyproject.toml" ]]     && echo "  ✦ Python (pyproject.toml)"
        [[ -f "$SCAN_DIR/Pipfile" ]]            && echo "  ✦ Python (Pipfile)"
        [[ -f "$SCAN_DIR/go.mod" ]]             && echo "  ✦ Go (go.mod)"
        [[ -f "$SCAN_DIR/Cargo.toml" ]]         && echo "  ✦ Rust (Cargo.toml)"
        [[ -f "$SCAN_DIR/Gemfile" ]]            && echo "  ✦ Ruby (Gemfile)"
        [[ -f "$SCAN_DIR/Dockerfile" ]]         && echo "  ✦ Docker (Dockerfile)"
        [[ -f "$SCAN_DIR/docker-compose.yml" ]] && echo "  ✦ Docker Compose"
        [[ -f "$SCAN_DIR/Makefile" ]]           && echo "  ✦ Makefile"
        echo ""

        # 可疑二進制檔
        echo "=== 二進制/可執行檔案 ==="
        find "$SCAN_DIR" -type f -not -path '*/.git/*' \
            \( -name "*.exe" -o -name "*.dll" -o -name "*.so" -o -name "*.dylib" \
            -o -name "*.bin" -o -name "*.dat" -o -name "*.msi" \) \
            2>/dev/null || echo "  （無）"

    } > "$info_file" 2>&1

    cat "$info_file"
    success "基本資訊已存入 $info_file"
}

# ─── Gitleaks 掃描 ────────────────────────────────────────────────────────────
run_gitleaks() {
    header "步驟 3：Gitleaks — Secrets 掃描"

    local report_json="$REPORT_DIR/01_gitleaks.json"
    local report_txt="$REPORT_DIR/01_gitleaks_summary.txt"

    info "掃描中...（偵測 API keys、passwords、tokens、private keys）"

    local exit_code=0
    if [[ -d "$SCAN_DIR/.git" ]]; then
        gitleaks git "$SCAN_DIR" \
            --report-format=json \
            --report-path="$report_json" \
            --redact \
            --verbose 2>&1 | tee "$REPORT_DIR/01_gitleaks_raw.log" || exit_code=$?
    else
        gitleaks dir "$SCAN_DIR" \
            --report-format=json \
            --report-path="$report_json" \
            --redact \
            --verbose 2>&1 | tee "$REPORT_DIR/01_gitleaks_raw.log" || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        success "Gitleaks: 未發現 secrets"
        echo "結果: 通過 — 未發現 secrets" > "$report_txt"
    else
        local count=0
        if [[ -f "$report_json" ]]; then
            count=$(jq length "$report_json" 2>/dev/null || echo "?")
        fi
        SCAN_EXIT_CODE=1
        warn "Gitleaks: 發現 ${count} 個潛在 secrets！"
        {
            echo "=== Gitleaks 掃描結果 ==="
            echo "發現: ${count} 個潛在 secrets"
            echo ""
            if [[ -f "$report_json" ]] && command -v jq &>/dev/null; then
                echo "摘要（Secret 值已遮蔽）:"
                echo "─────────────────────────────"
                jq -r '.[] | "規則: \(.RuleID)\n檔案: \(.File)\n行號: \(.StartLine)\n作者: \(.Author // "N/A")\nCommit: \(.Commit // "N/A")\n─────────────────────────────"' \
                    "$report_json" 2>/dev/null
            fi
        } > "$report_txt"
        echo ""
        cat "$report_txt"
    fi
}

# ─── Trivy 掃描 ──────────────────────────────────────────────────────────────
run_trivy() {
    header "步驟 4：Trivy — 漏洞與授權掃描"

    local report_json="$REPORT_DIR/02_trivy.json"
    local report_txt="$REPORT_DIR/02_trivy_summary.txt"

    info "掃描中...（偵測 CVE 漏洞、授權問題、設定錯誤）"

    # 檔案系統掃描（涵蓋所有語言的相依套件）
    trivy fs "$SCAN_DIR" \
        --format json \
        --output "$report_json" \
        --severity HIGH,CRITICAL \
        --scanners vuln,secret,misconfig \
        2>&1 | tee "$REPORT_DIR/02_trivy_raw.log" || true

    # 解析結果
    if [[ -f "$report_json" ]] && command -v jq &>/dev/null; then
        local total_vulns
        total_vulns=$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "$report_json" 2>/dev/null || echo 0)
        local total_secrets
        total_secrets=$(jq '[.Results[]?.Secrets // [] | length] | add // 0' "$report_json" 2>/dev/null || echo 0)
        local total_misconfig
        total_misconfig=$(jq '[.Results[]?.Misconfigurations // [] | length] | add // 0' "$report_json" 2>/dev/null || echo 0)

        {
            echo "=== Trivy 掃描結果 ==="
            echo "漏洞 (HIGH/CRITICAL): $total_vulns"
            echo "Secrets: $total_secrets"
            echo "設定錯誤: $total_misconfig"
            echo ""

            if [[ "$total_vulns" -gt 0 ]]; then
                echo "─── 漏洞詳情 ───"
                jq -r '
                    .Results[]? |
                    select(.Vulnerabilities != null) |
                    .Target as $target |
                    .Vulnerabilities[] |
                    "[\(.Severity)] \(.VulnerabilityID) — \(.PkgName) \(.InstalledVersion)\n  檔案: \($target)\n  說明: \(.Title // "N/A")\n  修復版本: \(.FixedVersion // "無")\n"
                ' "$report_json" 2>/dev/null
            fi

            if [[ "$total_misconfig" -gt 0 ]]; then
                echo "─── 設定錯誤詳情 ───"
                jq -r '
                    .Results[]? |
                    select(.Misconfigurations != null) |
                    .Target as $target |
                    .Misconfigurations[] |
                    "[\(.Severity)] \(.ID) — \(.Title)\n  檔案: \($target)\n  說明: \(.Description // "N/A")\n"
                ' "$report_json" 2>/dev/null
            fi
        } > "$report_txt"

        if [[ "$total_vulns" -eq 0 ]] && [[ "$total_secrets" -eq 0 ]] && [[ "$total_misconfig" -eq 0 ]]; then
            success "Trivy: 未發現 HIGH/CRITICAL 等級問題"
        else
            SCAN_EXIT_CODE=1
            warn "Trivy: 漏洞=$total_vulns  Secrets=$total_secrets  設定錯誤=$total_misconfig"
            echo ""
            head -50 "$report_txt"
            if [[ $(wc -l < "$report_txt") -gt 50 ]]; then info "...完整報告見 $report_txt"; fi
        fi
    else
        warn "Trivy 報告解析失敗，請檢查原始 log"
    fi
}

# ─── Bandit 掃描（Python 專案）────────────────────────────────────────────────
run_bandit() {
    # 只有偵測到 Python 專案才執行
    local has_python=false
    [[ -f "$SCAN_DIR/requirements.txt" ]] && has_python=true
    [[ -f "$SCAN_DIR/setup.py" ]]         && has_python=true
    [[ -f "$SCAN_DIR/pyproject.toml" ]]   && has_python=true
    [[ -f "$SCAN_DIR/Pipfile" ]]          && has_python=true
    if find "$SCAN_DIR" -maxdepth 3 -name "*.py" -not -path '*/.git/*' -print -quit | grep -q .; then
        has_python=true
    fi

    if ! $has_python; then
        info "未偵測到 Python 專案，跳過 Bandit 掃描"
        return
    fi

    if ! command -v bandit &>/dev/null; then
        warn "Bandit 未安裝，跳過 Python 靜態分析"
        return
    fi

    header "步驟 5a：Bandit — Python 靜態安全分析"

    local report_json="$REPORT_DIR/03_bandit.json"
    local report_txt="$REPORT_DIR/03_bandit_summary.txt"

    info "掃描 Python 程式碼..."

    bandit -r "$SCAN_DIR" \
        --format json \
        --output "$report_json" \
        -ll \
        --exclude '*/.git/*,*/node_modules/*,*/venv/*,*/.venv/*' \
        2>&1 || true

    if [[ -f "$report_json" ]] && command -v jq &>/dev/null; then
        local high_count medium_count
        high_count=$(jq '[.results[]? | select(.issue_severity == "HIGH")] | length' "$report_json" 2>/dev/null || echo 0)
        medium_count=$(jq '[.results[]? | select(.issue_severity == "MEDIUM")] | length' "$report_json" 2>/dev/null || echo 0)

        {
            echo "=== Bandit Python 安全掃描結果 ==="
            echo "HIGH: $high_count"
            echo "MEDIUM: $medium_count"
            echo ""
            jq -r '
                .results[]? |
                "[\(.issue_severity)] \(.test_id) — \(.issue_text)\n  檔案: \(.filename):\(.line_number)\n  信心: \(.issue_confidence)\n"
            ' "$report_json" 2>/dev/null
        } > "$report_txt"

        if [[ "$high_count" -eq 0 ]] && [[ "$medium_count" -eq 0 ]]; then
            success "Bandit: Python 程式碼未發現中高風險問題"
        else
            SCAN_EXIT_CODE=1
            warn "Bandit: HIGH=$high_count  MEDIUM=$medium_count"
            head -30 "$report_txt"
        fi
    fi
}

# ─── npm audit（Node.js 專案）─────────────────────────────────────────────────
run_npm_audit() {
    if [[ ! -f "$SCAN_DIR/package.json" ]]; then
        info "未偵測到 Node.js 專案，跳過 npm audit"
        return
    fi

    if ! command -v npm &>/dev/null; then
        warn "npm 未安裝，跳過 Node.js 相依掃描"
        return
    fi

    header "步驟 5b：npm audit — Node.js 相依套件漏洞"

    local report_json="$REPORT_DIR/04_npm_audit.json"
    local report_txt="$REPORT_DIR/04_npm_audit_summary.txt"

    info "掃描 Node.js 相依套件..."

    cd "$SCAN_DIR"

    # 安裝相依（不執行 scripts 以避免惡意程式碼）
    if [[ -f "package-lock.json" ]] || [[ -f "yarn.lock" ]]; then
        npm audit --json --audit-level=moderate > "$report_json" 2>/dev/null || true
    else
        warn "缺少 lock 檔案，先執行 npm install --ignore-scripts"
        npm install --ignore-scripts --no-fund --no-optional 2>&1 | tail -3
        npm audit --json --audit-level=moderate > "$report_json" 2>/dev/null || true
    fi

    if [[ -f "$report_json" ]] && command -v jq &>/dev/null; then
        local total high critical
        total=$(jq '.metadata.vulnerabilities.total // 0' "$report_json" 2>/dev/null || echo 0)
        high=$(jq '.metadata.vulnerabilities.high // 0' "$report_json" 2>/dev/null || echo 0)
        critical=$(jq '.metadata.vulnerabilities.critical // 0' "$report_json" 2>/dev/null || echo 0)

        {
            echo "=== npm audit 結果 ==="
            echo "總漏洞: $total"
            echo "HIGH: $high"
            echo "CRITICAL: $critical"
        } > "$report_txt"

        if [[ "$total" -eq 0 ]]; then
            success "npm audit: 未發現漏洞"
        else
            SCAN_EXIT_CODE=1
            warn "npm audit: 總計=$total (HIGH=$high, CRITICAL=$critical)"
        fi
    fi

    cd - > /dev/null
}

# ─── pip-audit（Python 專案）──────────────────────────────────────────────────
run_pip_audit() {
    if [[ ! -f "$SCAN_DIR/requirements.txt" ]]; then
        return
    fi

    if ! command -v pip-audit &>/dev/null; then
        info "pip-audit 未安裝，跳過 Python 相依漏洞掃描"
        return
    fi

    header "步驟 5c：pip-audit — Python 相依套件漏洞"

    local report_json="$REPORT_DIR/05_pip_audit.json"

    info "掃描 Python 相依套件..."

    pip-audit -r "$SCAN_DIR/requirements.txt" \
        --format json \
        --output "$report_json" \
        2>&1 || true

    if [[ -f "$report_json" ]]; then
        local vuln_count
        vuln_count=$(jq '[.dependencies[]? | select(.vulns | length > 0)] | length' "$report_json" 2>/dev/null || echo 0)
        if [[ "$vuln_count" -eq 0 ]]; then
            success "pip-audit: 未發現漏洞"
        else
            SCAN_EXIT_CODE=1
            warn "pip-audit: 發現 $vuln_count 個有漏洞的套件"
        fi
    fi
}

# ─── 自訂規則掃描 ─────────────────────────────────────────────────────────────
run_custom_checks() {
    header "步驟 6：自訂規則 — 可疑行為模式偵測"

    local report_txt="$REPORT_DIR/06_custom_checks.txt"
    local findings=0

    {
        echo "=== 自訂安全規則掃描結果 ==="
        echo "掃描時間: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        # --- 1. 可疑網路連線 ---
        echo "─── 1. 可疑網路活動模式 ───"
        local net_patterns=(
            "reverse.shell"
            "nc -[enlvp]"
            "ncat.*-e"
            "/dev/tcp/"
            "bash -i >& /dev/tcp"
            "mkfifo.*nc"
            "curl.*\| *sh"
            "curl.*\| *bash"
            "wget.*\| *sh"
            "wget.*\| *bash"
            "python.*socket.*connect"
            "socket\.socket.*SOCK_STREAM"
        )
        for pattern in "${net_patterns[@]}"; do
            local results
            results=$(grep -rn --include='*.py' --include='*.js' --include='*.ts' \
                --include='*.sh' --include='*.bash' --include='*.rb' --include='*.go' \
                --include='*.php' --include='*.pl' \
                -E "$pattern" "$SCAN_DIR" 2>/dev/null \
                | grep -v '.git/' | head -10) || true
            if [[ -n "$results" ]]; then
                echo "  [危險] 模式: $pattern"
                echo "$results" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        done

        # --- 2. 加密/混淆行為 ---
        echo "─── 2. 加密/混淆行為 ───"
        local obf_patterns=(
            "base64.*decode.*exec"
            "eval(.*base64"
            "exec(.*decode"
            "eval(.*compile"
            "exec(.*compile"
            "\\\\x[0-9a-fA-F]{2}.*\\\\x[0-9a-fA-F]{2}.*\\\\x[0-9a-fA-F]{2}"
            "fromCharCode.*fromCharCode"
            "String\.fromCharCode"
            "atob(.*eval"
        )
        for pattern in "${obf_patterns[@]}"; do
            local results
            results=$(grep -rn --include='*.py' --include='*.js' --include='*.ts' \
                --include='*.sh' --include='*.rb' --include='*.php' \
                -E "$pattern" "$SCAN_DIR" 2>/dev/null \
                | grep -v '.git/' | grep -v 'node_modules/' | head -10) || true
            if [[ -n "$results" ]]; then
                echo "  [警告] 模式: $pattern"
                echo "$results" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        done

        # --- 3. 挖礦行為 ---
        echo "─── 3. 加密貨幣挖礦指標 ───"
        local mining_patterns=(
            "stratum\+tcp"
            "xmrig"
            "coinhive"
            "cryptonight"
            "minergate"
            "hashrate"
            "mining.*pool"
            "monero.*wallet"
        )
        for pattern in "${mining_patterns[@]}"; do
            local results
            results=$(grep -rni "$pattern" "$SCAN_DIR" 2>/dev/null \
                | grep -v '.git/' | grep -v 'node_modules/' | head -5) || true
            if [[ -n "$results" ]]; then
                echo "  [危險] 挖礦指標: $pattern"
                echo "$results" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        done

        # --- 4. 可疑安裝腳本 ---
        echo "─── 4. 可疑安裝/建置腳本 ───"

        # 檢查 package.json 中的可疑 scripts
        if [[ -f "$SCAN_DIR/package.json" ]]; then
            local suspicious_scripts
            suspicious_scripts=$(jq -r '.scripts // {} | to_entries[] | select(
                (.key | test("pre|post|install|prepare")) and
                (.value | test("curl|wget|bash|sh |eval|exec|node -e|python -c"))
            ) | "\(.key): \(.value)"' "$SCAN_DIR/package.json" 2>/dev/null) || true

            if [[ -n "$suspicious_scripts" ]]; then
                echo "  [警告] package.json 中的可疑 scripts:"
                echo "$suspicious_scripts" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        fi

        # 檢查 setup.py 中的可疑行為
        if [[ -f "$SCAN_DIR/setup.py" ]]; then
            local setup_suspicious
            setup_suspicious=$(grep -n -E \
                'os\.system|subprocess|exec\(|eval\(|urllib|requests\.get|curl|wget' \
                "$SCAN_DIR/setup.py" 2>/dev/null) || true
            if [[ -n "$setup_suspicious" ]]; then
                echo "  [警告] setup.py 中的可疑程式碼:"
                echo "$setup_suspicious" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        fi

        # 檢查 Makefile 中的可疑行為
        if [[ -f "$SCAN_DIR/Makefile" ]]; then
            local make_suspicious
            make_suspicious=$(grep -n -E \
                'curl.*\|.*sh|wget.*\|.*sh|rm -rf /|chmod 777|/dev/tcp' \
                "$SCAN_DIR/Makefile" 2>/dev/null) || true
            if [[ -n "$make_suspicious" ]]; then
                echo "  [警告] Makefile 中的可疑指令:"
                echo "$make_suspicious" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        fi

        # --- 5. typosquatting 檢查（常見套件拼字變體）---
        echo "─── 5. Typosquatting 檢查 ───"
        if [[ -f "$SCAN_DIR/requirements.txt" ]]; then
            local typo_suspects=(
                "requets" "reqeusts" "reequests"      # requests
                "djang" "djnago"                       # django
                "flak" "flaask"                         # flask
                "numpyy" "nunpy"                        # numpy
                "pandsa" "pnadas"                       # pandas
                "scikitlearn" "sklearn"                 # scikit-learn
                "criptography" "crytography"           # cryptography
            )
            for suspect in "${typo_suspects[@]}"; do
                if grep -qi "^${suspect}" "$SCAN_DIR/requirements.txt" 2>/dev/null; then
                    echo "  [危險] 可能的 typosquatting 套件: $suspect"
                    ((findings++)) || true
                fi
            done
        fi

        if [[ -f "$SCAN_DIR/package.json" ]]; then
            local npm_typo_suspects=(
                "lodasH" "lodahs" "lod-ash"            # lodash
                "axois" "axos"                          # axios
                "epxress" "expresss"                    # express
                "reactt" "recat"                        # react
                "electorn" "electronn"                  # electron
                "event-streem" "event_stream"           # event-stream
            )
            for suspect in "${npm_typo_suspects[@]}"; do
                if jq -e ".dependencies.\"$suspect\" // .devDependencies.\"$suspect\"" \
                    "$SCAN_DIR/package.json" &>/dev/null; then
                    echo "  [危險] 可能的 typosquatting 套件: $suspect"
                    ((findings++)) || true
                fi
            done
        fi

        # --- 6. 資料外洩跡象 ---
        echo "─── 6. 資料外洩/蒐集跡象 ───"
        local exfil_patterns=(
            "os\.environ.*get.*KEY"
            "os\.environ.*get.*SECRET"
            "os\.environ.*get.*TOKEN"
            "os\.environ.*get.*PASSWORD"
            "keylogger"
            "screenshot.*capture"
            "clipboard.*get"
            "browser.*cookie"
            "chrome.*password"
            "firefox.*login"
        )
        for pattern in "${exfil_patterns[@]}"; do
            local results
            results=$(grep -rn --include='*.py' --include='*.js' --include='*.ts' \
                --include='*.rb' --include='*.go' \
                -E "$pattern" "$SCAN_DIR" 2>/dev/null \
                | grep -v '.git/' | grep -v 'node_modules/' \
                | grep -v 'test' | grep -v 'example' | grep -v 'README' \
                | head -5) || true
            if [[ -n "$results" ]]; then
                echo "  [注意] 模式: $pattern"
                echo "$results" | sed 's/^/    /'
                echo ""
                ((findings++)) || true
            fi
        done

        echo ""
        echo "=== 自訂規則掃描結束 ==="
        echo "發現: $findings 個項目"

    } > "$report_txt" 2>&1

    if [[ $findings -eq 0 ]]; then
        success "自訂規則: 未發現可疑行為模式"
    else
        SCAN_EXIT_CODE=1
        warn "自訂規則: 發現 $findings 個可疑項目"
        cat "$report_txt"
    fi
}

# ─── 產生最終報告 ─────────────────────────────────────────────────────────────
generate_final_report() {
    header "步驟 7：產生最終報告"

    local final_report="$REPORT_DIR/FINAL_REPORT.md"

    {
        echo "# 🔒 Repo 安全掃描報告"
        echo ""
        echo "| 項目 | 值 |"
        echo "|------|------|"
        echo "| Repo | \`$REPO_NAME\` |"
        echo "| 掃描時間 | $(date '+%Y-%m-%d %H:%M:%S') |"
        echo "| 掃描路徑 | \`$SCAN_DIR\` |"
        echo ""
        echo "## 掃描結果摘要"
        echo ""

        # Gitleaks
        echo "### 1. Gitleaks (Secrets)"
        if [[ -f "$REPORT_DIR/01_gitleaks.json" ]]; then
            local gl_count
            gl_count=$(jq length "$REPORT_DIR/01_gitleaks.json" 2>/dev/null || echo 0)
            if [[ "$gl_count" -eq 0 ]]; then
                echo "- ✅ 通過 — 未發現 secrets"
            else
                echo "- ⚠️ 發現 **${gl_count}** 個潛在 secrets"
                echo "- 詳見: \`01_gitleaks.json\`"
            fi
        else
            echo "- ✅ 通過 — 未發現 secrets"
        fi
        echo ""

        # Trivy
        echo "### 2. Trivy (漏洞/設定)"
        if [[ -f "$REPORT_DIR/02_trivy.json" ]]; then
            local tv=$(jq '[.Results[]?.Vulnerabilities // [] | length] | add // 0' "$REPORT_DIR/02_trivy.json" 2>/dev/null || echo 0)
            local ts=$(jq '[.Results[]?.Secrets // [] | length] | add // 0' "$REPORT_DIR/02_trivy.json" 2>/dev/null || echo 0)
            local tm=$(jq '[.Results[]?.Misconfigurations // [] | length] | add // 0' "$REPORT_DIR/02_trivy.json" 2>/dev/null || echo 0)
            if [[ "$tv" -eq 0 ]] && [[ "$ts" -eq 0 ]] && [[ "$tm" -eq 0 ]]; then
                echo "- ✅ 通過"
            else
                echo "- ⚠️ 漏洞: **$tv** | Secrets: **$ts** | 設定錯誤: **$tm**"
                echo "- 詳見: \`02_trivy.json\`"
            fi
        else
            echo "- ℹ️ 未執行或無結果"
        fi
        echo ""

        # Bandit
        echo "### 3. Bandit (Python)"
        if [[ -f "$REPORT_DIR/03_bandit.json" ]]; then
            local bh=$(jq '[.results[]? | select(.issue_severity == "HIGH")] | length' "$REPORT_DIR/03_bandit.json" 2>/dev/null || echo 0)
            if [[ "$bh" -eq 0 ]]; then
                echo "- ✅ 通過"
            else
                echo "- ⚠️ 發現 **$bh** 個高風險問題"
            fi
        else
            echo "- ℹ️ 未執行（非 Python 專案或 Bandit 未安裝）"
        fi
        echo ""

        # npm audit
        echo "### 4. npm audit (Node.js)"
        if [[ -f "$REPORT_DIR/04_npm_audit.json" ]]; then
            local na=$(jq '.metadata.vulnerabilities.total // 0' "$REPORT_DIR/04_npm_audit.json" 2>/dev/null || echo 0)
            if [[ "$na" -eq 0 ]]; then
                echo "- ✅ 通過"
            else
                echo "- ⚠️ 發現 **$na** 個漏洞"
            fi
        else
            echo "- ℹ️ 未執行（非 Node.js 專案）"
        fi
        echo ""

        # 自訂規則
        echo "### 5. 自訂規則 (行為分析)"
        if [[ -f "$REPORT_DIR/06_custom_checks.txt" ]]; then
            local cc
            cc=$(grep "發現:.*個項目" "$REPORT_DIR/06_custom_checks.txt" | grep -o '[0-9]*' | tail -1)
            if [[ "${cc:-0}" -eq 0 ]]; then
                echo "- ✅ 通過"
            else
                echo "- ⚠️ 發現 **$cc** 個可疑模式"
                echo "- 詳見: \`06_custom_checks.txt\`"
            fi
        fi
        echo ""

        # 建議
        echo "## 🎯 建議"
        echo ""
        echo "1. 若有發現 secrets：該 repo 可能已經洩漏金鑰，不要在生產環境使用"
        echo "2. 若有 HIGH/CRITICAL 漏洞：檢查是否有可用修補版本"
        echo "3. 若有可疑行為模式：在 VM/Docker 中隔離測試，不要直接在主機執行"
        echo "4. 所有 JSON 報告可匯入 VS Code、Defect Dojo 等工具做進階分析"
        echo ""
        echo "---"
        echo "*報告由 repo_security_scan.sh 自動產生*"

    } > "$final_report"

    success "最終報告已產生: $final_report"
    echo ""
    cat "$final_report"
}

# ─── 清理 ─────────────────────────────────────────────────────────────────────
cleanup() {
    if [[ "${IS_CLONED:-false}" == "true" ]] && [[ -d "${SCAN_DIR:-}" ]]; then
        info "清理暫存的 clone 目錄..."
        rm -rf "$SCAN_DIR"
        success "已清理: $SCAN_DIR"
    fi
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║   🔒 GitHub Repo 自動化安全掃描工具      ║"
    echo "  ║   v1.0 — Gitleaks + Trivy + 自訂規則     ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    check_tools
    prepare_repo
    gather_info
    run_gitleaks
    run_trivy
    run_bandit
    run_npm_audit
    run_pip_audit
    run_custom_checks
    generate_final_report
    cleanup

    echo ""
    echo -e "${BOLD}${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  掃描完成！報告目錄: $REPORT_DIR${NC}"
    echo -e "${BOLD}${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    echo "檢視報告:"
    echo "  cat $REPORT_DIR/FINAL_REPORT.md"
    echo "  ls -la $REPORT_DIR/"

    exit "$SCAN_EXIT_CODE"
}

trap cleanup EXIT
main
