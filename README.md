# Safe Clone - Isolated Repo Security Scanner

> [繁體中文版](README.zh-TW.md)

Scan untrusted repos inside a Docker sandbox before cloning to your host.

## Architecture

Two-layer design: the host orchestrates, the container does all the dirty work.

```
  Your Mac (Host)                          Docker Container (Isolated)
  ┌─────���─────────────��─────┐             ┌────────────────────────────────┐
  │  safe-clone.sh          │─��docker run─▶│  repo_security_scan.sh        │
  │  (Orchestrator)         │             │  (Scanner)                     │
  │                         │             ��                                │
  │  1. GitHub API preflight│             │  1. git clone (hooks disabled) │
  │  2. Launch Docker       │             │  2. Gitleaks — secrets         ��
  │  3. Collect reports     │◀─vol mount──│  3. Trivy — CVE & misconfig   │
  ��  4. Destroy container   │             │  4. Bandit — Python            │
  └��─────────────��──────────┘             │  5. npm audit — Node.js        │
                                          │  6. pip-audit — Python deps    │
                                          │  7. Custom rules — behaviors   │
                                          │  8. Generate report → /output  │
                                          └─────────────��──────────────────┘
```

## Why?

You find an interesting repo on GitHub and want to clone it. But:

- Git hooks can execute arbitrary code during clone
- Malicious scripts may hide in `package.json` `postinstall`
- Secrets may have leaked in commit history
- Dependencies may have known vulnerabilities

**Safe Clone** runs all checks in a Docker isolated environment. Your host is never touched.

## Features

| Scan | Tool | Detects |
|------|------|---------|
| Secrets | [Gitleaks](https://github.com/gitleaks/gitleaks) | API keys, passwords, tokens, private keys |
| Vulnerabilities | [Trivy](https://github.com/aquasecurity/trivy) | CVEs, license issues, misconfigurations |
| Python static analysis | [Bandit](https://github.com/PyCQA/bandit) | Python security issues |
| Node.js deps | npm audit | Known npm package vulnerabilities |
| Python deps | [pip-audit](https://github.com/pypa/pip-audit) | Known Python package vulnerabilities |
| Behavior analysis | Custom rules | Reverse shells, crypto mining, obfuscation, typosquatting |

### Security Measures

- **GitHub API preflight** ��� Risk assessment before clone (stars, age, owner)
- **Docker sandbox** — `--cap-drop=ALL`, `--security-opt=no-new-privileges`, resource limits
- **Git hooks disabled** — `core.hooksPath=/dev/null` during clone
- **Trivy DB cache** — Named volume, no re-download every scan

## Prerequisites

- Docker

That's it. All scanning tools are bundled in the Docker image.

## Install

```bash
git clone https://github.com/aiondaily/safe-clone.git
cd safe-clone
chmod +x safe-clone.sh
```

## Usage

```bash
# Scan a GitHub repo
./safe-clone.sh https://github.com/someone/cool-project

# Skip GitHub API preflight
./safe-clone.sh --no-preflight https://github.com/someone/cool-project

# Force scan high-risk repo
./safe-clone.sh --force https://github.com/someone/sketchy-repo

# Build/update Docker image only
./safe-clone.sh --build

# Keep container after scan (debug)
./safe-clone.sh --keep https://github.com/someone/cool-project
```

### Run scanner directly (without Docker)

If you already have gitleaks, trivy, etc. installed locally:

```bash
# Scan remote repo
./repo_security_scan.sh https://github.com/someone/cool-project

# Scan local directory
./repo_security_scan.sh ./my-local-repo
```

## Report Output

Reports are saved to `scan_reports/<repo_name>_<timestamp>/`:

```
scan_reports/cool-project_20260328_143000/
├── 00_repo_info.txt            # Repo metadata
├── 01_gitleaks.json            # Secrets scan
├── 01_gitleaks_summary.txt
├── 02_trivy.json               # Vulnerability scan
├── 02_trivy_summary.txt
├── 03_bandit.json              # Python analysis (if applicable)
├── 04_npm_audit.json           # npm vulnerabilities (if applicable)
├── 05_pip_audit.json           # pip vulnerabilities (if applicable)
├── 06_custom_checks.txt        # Behavior analysis
└── FINAL_REPORT.md             # Summary report
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Pass — no issues found |
| 1 | Security risks detected |
| 2 | Tool execution error |

## GitHub Token (Optional)

Set `GITHUB_TOKEN` to avoid API rate limits:

```bash
export GITHUB_TOKEN=ghp_your_token_here
./safe-clone.sh https://github.com/someone/cool-project
```

## License

MIT - See [LICENSE](LICENSE)
