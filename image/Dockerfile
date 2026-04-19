# Base image supports future sbx retargeting via BASE_IMAGE build arg
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq iptables sudo \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (for claude CLI npm install)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install claude CLI (official npm package)
RUN npm install -g @anthropic-ai/claude-code@latest

# Non-root user with sudo, matching sbx template convention for future portability
RUN useradd -m -s /bin/bash -G sudo agent \
    && echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent

# Copy pipeline assets
COPY --chown=root:root image/opt/pal /opt/pal
RUN chmod +x /opt/pal/entrypoint.sh /opt/pal/lib/*.sh 2>/dev/null || true

# Run as agent user by default
USER agent
WORKDIR /home/agent

ENTRYPOINT ["/opt/pal/entrypoint.sh"]
