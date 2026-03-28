# Safe Clone - Isolated Repo Security Scanner

Scan untrusted repos inside a Docker sandbox before cloning to your host.

在 Docker 沙箱裡掃描不信任的 repo，再決定要不要 clone 到你的主機。

---

## Architecture | 架構

Two-layer design: the host orchestrates, the container does all the dirty work.

兩層設計：Host 負責指揮，容器負責所有髒活。

```
  Your Mac (Host)                          Docker Container (Isolated)
  ┌─────────────────────────┐             ┌────────────────────────────────┐
  │  safe-clone.sh          │──docker run─▶│  repo_security_scan.sh        │
  │  (Orchestrator)         │             │  (Scanner)                     │
  │                         │             │                                │
  │  1. GitHub API preflight│             │  1. git clone (hooks disabled) │
  │  2. Launch Docker       │             │  2. Gitleaks — secrets         │
  │  3. Collect reports     │◀─vol mount──│  3. Trivy — CVE & misconfig   │
  │  4. Destroy container   │             │  4. Bandit — Python            │
  └─────────────────────────┘             │  5. npm audit — Node.js        │
                                          │  6. pip-audit — Python deps    │
                                          │  7. Custom rules — behaviors   │
                                          │  8. Generate report → /output  │
                                          └────────────────────────────────┘
```

## Why? | 為什麼需要這個？

You find an interesting repo on GitHub and want to clone it. But:

你在 GitHub 上看到一個有趣的 repo，想 clone 下來看看。但：

- Git hooks can execute arbitrary code during clone | Git hooks 可以在 clone 時執行任意程式碼
- Malicious scripts may hide in `package.json` `postinstall` | 惡意腳本可能藏在 `postinstall` 裡
- Secrets may have leaked in commit history | Secrets 可能洩漏在 commit history 中
- Dependencies may have known vulnerabilities | 依賴套件可能有已知漏洞

**Safe Clone** runs all checks in a Docker isolated environment. Your host is never touched.

**Safe Clone** 在 Docker 隔離環境中完成所有檢查，你的主機完全不會被碰到。

## Features | 功能

| Scan | Tool | Detects |
|------|------|---------|
| Secrets | [Gitleaks](https://github.com/gitleaks/gitleaks) | API keys, passwords, tokens, private keys |
| Vulnerabilities | [Trivy](https://github.com/aquasecurity/trivy) | CVEs, license issues, misconfigurations |
| Python static analysis | [Bandit](https://github.com/PyCQA/bandit) | Python security issues |
| Node.js deps | npm audit | Known npm package vulnerabilities |
| Python deps | [pip-audit](https://github.com/pypa/pip-audit) | Known Python package vulnerabilities |
| Behavior analysis | Custom rules | Reverse shells, crypto mining, obfuscation, typosquatting |

### Security Measures | 安全措施

- **GitHub API preflight** — Risk assessment before clone (stars, age, owner) | clone 前先評估風險
- **Docker sandbox** — `--cap-drop=ALL`, `--security-opt=no-new-privileges`, resource limits | 完整沙箱隔離
- **Git hooks disabled** — `core.hooksPath=/dev/null` during clone | clone 時禁用 hooks
- **Trivy DB cache** — Named volume, no re-download every scan | 持久化 cache，不用每次重新下載

## Prerequisites | 前置需求

- Docker

That's it. All scanning tools are bundled in the Docker image.

就這樣。所有掃描工具都包在 Docker image 裡。

## Install | 安裝

```bash
git clone https://github.com/aiondaily/safe-clone.git
cd safe-clone
chmod +x safe-clone.sh
```

## Usage | 使用方式

```bash
# Scan a GitHub repo | 掃描一個 GitHub repo
./safe-clone.sh https://github.com/someone/cool-project

# Skip GitHub API preflight | 跳過 API 預檢
./safe-clone.sh --no-preflight https://github.com/someone/cool-project

# Force scan high-risk repo | 高風險 repo 強制掃描
./safe-clone.sh --force https://github.com/someone/sketchy-repo

# Build/update Docker image only | 僅建置 Docker image
./safe-clone.sh --build

# Keep container after scan (debug) | 掃描後保留容器（除錯用）
./safe-clone.sh --keep https://github.com/someone/cool-project
```

### Run scanner directly (without Docker) | 直接使用掃描腳本（不透過 Docker）

If you already have gitleaks, trivy, etc. installed locally:

如果你已經安裝了 gitleaks、trivy 等工具：

```bash
# Scan remote repo | 掃描遠端 repo
./repo_security_scan.sh https://github.com/someone/cool-project

# Scan local directory | 掃描本地目錄
./repo_security_scan.sh ./my-local-repo
```

## Report Output | 報告輸出

Reports are saved to `scan_reports/<repo_name>_<timestamp>/`:

掃描完成後，報告存放在 `scan_reports/<repo_name>_<timestamp>/`：

```
scan_reports/cool-project_20260328_143000/
├── 00_repo_info.txt            # Repo metadata | repo 基本資訊
├── 01_gitleaks.json            # Secrets scan | secrets 掃描結果
├── 01_gitleaks_summary.txt
├── 02_trivy.json               # Vulnerability scan | 漏洞掃描結果
├── 02_trivy_summary.txt
├── 03_bandit.json              # Python analysis (if applicable)
├── 04_npm_audit.json           # npm vulnerabilities (if applicable)
├── 05_pip_audit.json           # pip vulnerabilities (if applicable)
├── 06_custom_checks.txt        # Behavior analysis | 行為分析
└── FINAL_REPORT.md             # Summary report | 總結報告
```

## Exit Codes | 退出碼

| Code | Meaning |
|------|---------|
| 0 | Pass — no issues found | 通過 |
| 1 | Security risks detected | 發現安全風險 |
| 2 | Tool execution error | 工具執行錯誤 |

## GitHub Token (Optional) | GitHub Token（選用）

Set `GITHUB_TOKEN` to avoid API rate limits:

設定 `GITHUB_TOKEN` 環境變數可避免 API rate limit：

```bash
export GITHUB_TOKEN=ghp_your_token_here
./safe-clone.sh https://github.com/someone/cool-project
```

## License

MIT - See [LICENSE](LICENSE)
