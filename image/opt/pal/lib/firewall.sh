# image/opt/pal/lib/firewall.sh
# shellcheck shell=bash
# Apply deny-by-default outbound allowlist via iptables.
# Requires: iptables, dig (via host command), sudo
# Inputs: allowlist.yaml (domains list) + PAL_ALLOWLIST_EXTRA_DOMAINS env var

apply_firewall() {
    local allowlist_file="${1:-/opt/pal/allowlist.yaml}"
    local extra_domains_csv="${PAL_ALLOWLIST_EXTRA_DOMAINS:-}"

    if [ ! -f "$allowlist_file" ]; then
        log "firewall: allowlist file not found at $allowlist_file"
        return 1
    fi

    # Parse YAML (jq via yq-lite approach: very limited schema, one-level 'domains' list)
    local domains
    domains=$(awk '/^domains:/{flag=1;next}/^[^[:space:]-]/{flag=0}flag&&/^[[:space:]]*-[[:space:]]+/{gsub(/^[[:space:]]*-[[:space:]]+/,""); print}' "$allowlist_file")

    if [ -n "$extra_domains_csv" ]; then
        domains+=$'\n'
        domains+=$(printf '%s\n' "$extra_domains_csv" | tr ',' '\n' | tr -d ' ')
    fi

    log "firewall: allowlist contains $(printf '%s\n' "$domains" | grep -c . || true) domains"

    # Default policy: allow all loopback, deny all other outbound initially
    sudo iptables -F OUTPUT
    sudo iptables -P OUTPUT DROP
    sudo iptables -A OUTPUT -o lo -j ACCEPT
    # Allow DNS to resolver (so we can resolve domain names to IPs below)
    sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    sudo iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    # Allow established/related inbound responses
    sudo iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        local ips
        ips=$(getent ahosts "$domain" | awk '{print $1}' | sort -u || true)
        if [ -z "$ips" ]; then
            log "firewall: warning, could not resolve $domain (skipping)"
            continue
        fi
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            sudo iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
            sudo iptables -A OUTPUT -d "$ip" -p tcp --dport 80 -j ACCEPT
        done <<< "$ips"
    done <<< "$domains"

    log "firewall: allowlist applied (default-DROP with IP-pinned ACCEPT rules)"
}

# Re-resolve a domain and append iptables rules for any new IPs. Call before
# latency-sensitive ops (e.g. git push) to tolerate GitHub's IP rotation.
refresh_firewall_for() {
    local domain="$1"
    local ips
    ips=$(getent ahosts "$domain" | awk '{print $1}' | sort -u || true)
    if [ -z "$ips" ]; then
        log "firewall-refresh: could not resolve $domain"
        return 0
    fi
    local added=0
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        if ! sudo iptables -C OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
            sudo iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
            added=$((added+1))
        fi
    done <<< "$ips"
    if [ "$added" -gt 0 ]; then
        log "firewall-refresh: added $added new IP rule(s) for $domain"
    fi
}
