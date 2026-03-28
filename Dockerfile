FROM python:3.12-slim

# ─── 系統相依 ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl wget jq npm unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ─── Gitleaks ────────────────────────────────────────────────────────────────
ARG GITLEAKS_VERSION=8.21.2
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then GL_ARCH="arm64"; else GL_ARCH="x64"; fi && \
    curl -sSfL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${GL_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin gitleaks

# ─── Trivy ───────────────────────────────────────────────────────────────────
ARG TRIVY_VERSION=0.69.3
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then TV_ARCH="ARM64"; else TV_ARCH="64bit"; fi && \
    curl -sSfL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-${TV_ARCH}.tar.gz" \
        | tar -xz -C /usr/local/bin trivy

# ─── Python 掃描工具 ─────────────────────────────────────────────────────────
RUN pip install --no-cache-dir bandit pip-audit

# ─── 非 root 使用者（最小權限原則）────────────────────────────────────────────
RUN useradd -r -u 1001 -s /sbin/nologin -d /home/scanner scanner && \
    mkdir -p /home/scanner && \
    chown scanner:scanner /home/scanner
ENV TRIVY_CACHE_DIR=/home/scanner/.cache/trivy

# ─── 工作目錄 ────────────────────────────────────────────────────────────────
WORKDIR /workspace
COPY repo_security_scan.sh /usr/local/bin/repo_security_scan.sh
RUN chmod +x /usr/local/bin/repo_security_scan.sh && \
    mkdir -p /workspace/scan_reports && \
    chown -R scanner:scanner /workspace

USER scanner

ENTRYPOINT ["/usr/local/bin/repo_security_scan.sh"]
