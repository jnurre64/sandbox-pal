# syntax=docker/dockerfile:1.6
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg iptables ipset jq sudo \
        unzip zip bash less man-db procps \
    && rm -rf /var/lib/apt/lists/*

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# claude CLI (native binary installer)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Non-root agent user. UID 1000 matches typical host users but is not required
# (named volume owns its permissions). Ubuntu 24.04's base image ships a
# default `ubuntu` user already at UID 1000 — remove it before claiming the UID
# for `agent`.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd --create-home --shell /bin/bash --uid 1000 agent \
    && mkdir -p /home/agent/.claude /home/agent/work /status \
    && chown -R agent:agent /home/agent /status

# Firewall caps are granted at `docker run --cap-add NET_ADMIN --cap-add NET_RAW`
# time; we still need sudo here so workspace-boot.sh can program iptables.
RUN echo "agent ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/ip6tables, /usr/sbin/ipset, /bin/cp" \
        > /etc/sudoers.d/10-agent-firewall \
    && chmod 0440 /etc/sudoers.d/10-agent-firewall

COPY --chown=agent:agent image/opt/pal/ /opt/pal/
RUN chmod +x /opt/pal/workspace-boot.sh /opt/pal/run-pipeline.sh \
    && find /opt/pal/lib -name '*.sh' -exec chmod +x {} +

USER agent
WORKDIR /home/agent
VOLUME ["/home/agent/.claude"]

CMD ["/opt/pal/workspace-boot.sh"]
