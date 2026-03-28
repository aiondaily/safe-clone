# Safe Clone - 隔離式 Repo 安全掃描工具

> [English](README.en.md)

Clone 前先在 Docker 沙箱裡掃描不信任的 repo，防止惡意程式碼攻擊你的主機。

## 架構

兩層設計：Host 負責指揮，容器負責所有髒活。

```
  你的 Mac (Host)                          Docker 容器 (隔離環境)
  ┌─────────────────────────┐             ┌────────────────────────────────┐
  │  safe-clone.sh          │──docker run─▶│  repo_security_scan.sh        │
  │  (指揮官)               │             │  (實際執行掃描)               │
  │                         │             │                                │
  │  1. GitHub API 預檢     │             │  1. git clone (hooks 已禁用)   │
  │  2. 啟動 Docker         │             │  2. Gitleaks — 掃 secrets      │
  │  3. 收報告              │◀─vol mount──│  3. Trivy — 掃漏洞與設定錯誤   │
  │  4. 銷毀容器            │             │  4. Bandit — 掃 Python         │
  └─────────────────────────┘             │  5. npm audit — 掃 Node.js     │
                                          │  6. pip-audit — 掃 Python 依賴 │
                                          │  7. 自訂規則 — 掃行為模式      │
                                          │  8. 產生報告 → /output         │
                                          └────────────────────────────────┘
```

## 為什麼需要這個？

你在 GitHub 上看到一個有趣的 repo，想 clone 下來看看。但：

- Git hooks 可以在 clone 時執行任意程式碼
- 惡意腳本可能藏在 `package.json` 的 `postinstall` 裡
- Secrets 可能洩漏在 commit history 中
- 依賴套件可能有已知漏洞

**Safe Clone** 在 Docker 隔離環境中完成所有檢查，你的主機完全不會被碰到。

## 功能

| 掃描項目 | 工具 | 偵測內容 |
|---------|------|---------|
| Secrets | [Gitleaks](https://github.com/gitleaks/gitleaks) | API keys、passwords、tokens、private keys |
| 漏洞 | [Trivy](https://github.com/aquasecurity/trivy) | CVE 漏洞、授權問題、設定錯誤 |
| Python 靜態分析 | [Bandit](https://github.com/PyCQA/bandit) | Python 程式碼安全問題 |
| Node.js 依賴 | npm audit | npm 套件已知漏洞 |
| Python 依賴 | [pip-audit](https://github.com/pypa/pip-audit) | Python 套件已知漏洞 |
| 行為分析 | 自訂規則 | 反向 shell、挖礦、混淆、typosquatting |

### 安全措施

- **GitHub API 預檢** — clone 前先評估 repo 風險（stars、年齡、owner）
- **Docker 沙箱** — `--cap-drop=ALL`、`--security-opt=no-new-privileges`、資源限制
- **Git hooks 禁用** — clone 時設定 `core.hooksPath=/dev/null`
- **Trivy DB 持久化** — named volume cache，不用每次重新下載

## 前置需求

- Docker

就這樣。所有掃描工具都包在 Docker image 裡。

## 安裝

```bash
git clone https://github.com/aiondaily/safe-clone.git
cd safe-clone
chmod +x safe-clone.sh
```

## 使用方式

```bash
# 掃描一個 GitHub repo
./safe-clone.sh https://github.com/someone/cool-project

# 跳過 GitHub API 預檢
./safe-clone.sh --no-preflight https://github.com/someone/cool-project

# 高風險 repo 強制掃描
./safe-clone.sh --force https://github.com/someone/sketchy-repo

# 僅建置/更新 Docker image
./safe-clone.sh --build

# 掃描後保留容器（除錯用）
./safe-clone.sh --keep https://github.com/someone/cool-project
```

### 直接使用掃描腳本（不透過 Docker）

如果你已經安裝了 gitleaks、trivy 等工具，可以直接使用：

```bash
# 掃描遠端 repo
./repo_security_scan.sh https://github.com/someone/cool-project

# 掃描本地目錄
./repo_security_scan.sh ./my-local-repo
```

## 報告輸出

掃描完成後，報告存放在 `scan_reports/<repo_name>_<timestamp>/`：

```
scan_reports/cool-project_20260328_143000/
├── 00_repo_info.txt            # repo 基本資訊
├── 01_gitleaks.json            # secrets 掃描結果
├── 01_gitleaks_summary.txt
├── 02_trivy.json               # 漏洞掃描結果
├── 02_trivy_summary.txt
├── 03_bandit.json              # Python 靜態分析（如適用）
├── 04_npm_audit.json           # npm 漏洞（如適用）
├── 05_pip_audit.json           # pip 漏洞（如適用）
├── 06_custom_checks.txt        # 行為分析
└── FINAL_REPORT.md             # 總結報告
```

## 退出碼

| 代碼 | 意義 |
|------|------|
| 0 | 通過 — 未發現問題 |
| 1 | 發現安全風險 |
| 2 | 工具執行錯誤 |

## GitHub Token（選用）

設定 `GITHUB_TOKEN` 環境變數可避免 API rate limit：

```bash
export GITHUB_TOKEN=ghp_your_token_here
./safe-clone.sh https://github.com/someone/cool-project
```

## 授權

MIT - 詳見 [LICENSE](LICENSE)
