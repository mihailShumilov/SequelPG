#!/usr/bin/env bash
# Generates the throwaway TLS + SSH material the test cluster needs into
# test-db/.generated/ (git-ignored). Idempotent: existing files are kept so
# the pinned SSH host key — and therefore known_hosts — stays stable.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=.generated
mkdir -p "$OUT/certs" "$OUT/ssh"
SSH_PORT=$(python3 -c 'import json;print(json.load(open("test-env.json"))["ssh"]["port"])')

# ── TLS: private CA + server cert for localhost/127.0.0.1 ──────────────
if [[ ! -f "$OUT/certs/server.crt" ]]; then
    echo "Generating test CA and server certificate…"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=SequelPG Test CA" \
        -keyout "$OUT/certs/ca.key" -out "$OUT/certs/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes \
        -subj "/CN=localhost" \
        -keyout "$OUT/certs/server.key" -out "$OUT/certs/server.csr" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > "$OUT/certs/server.ext"
    openssl x509 -req -in "$OUT/certs/server.csr" -days 3650 \
        -CA "$OUT/certs/ca.crt" -CAkey "$OUT/certs/ca.key" -CAcreateserial -CAserial "$OUT/certs/ca.srl" \
        -extfile "$OUT/certs/server.ext" -out "$OUT/certs/server.crt" 2>/dev/null
    rm -f "$OUT/certs/server.csr" "$OUT/certs/server.ext"
fi
# Docker Desktop maps mounted files' ownership; the init script re-installs
# them with the right mode, so world-readable here is fine (throwaway keys).
chmod 644 "$OUT"/certs/*

# ── SSH: pinned host key + client key pair ─────────────────────────────
if [[ ! -f "$OUT/ssh/ssh_host_ed25519_key" ]]; then
    echo "Generating SSH host and client keys…"
    ssh-keygen -q -t ed25519 -N '' -C 'sequelpg-test-host' -f "$OUT/ssh/ssh_host_ed25519_key"
    ssh-keygen -q -t ed25519 -N '' -C 'sequelpg-test-client' -f "$OUT/ssh/client_ed25519"
fi
chmod 644 "$OUT/ssh/ssh_host_ed25519_key" "$OUT/ssh/ssh_host_ed25519_key.pub" "$OUT/ssh/client_ed25519.pub"
# The app hands this key to /usr/bin/ssh, which rejects group/world-readable
# private keys — keep a 0600 copy for clients.
chmod 600 "$OUT/ssh/client_ed25519"

# known_hosts used ONLY by test runs (DEBUG builds honour
# SEQUELPG_SSH_KNOWN_HOSTS_FILE); the user's ~/.ssh/known_hosts is untouched.
HOSTKEY=$(cut -d' ' -f1,2 "$OUT/ssh/ssh_host_ed25519_key.pub")
echo "[127.0.0.1]:$SSH_PORT $HOSTKEY" > "$OUT/ssh/known_hosts"
chmod 644 "$OUT/ssh/known_hosts"

# A key the bastion does NOT accept, for negative tests.
if [[ ! -f "$OUT/ssh/wrong_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'sequelpg-test-wrong' -f "$OUT/ssh/wrong_ed25519"
fi
chmod 600 "$OUT/ssh/wrong_ed25519"
echo "Assets ready in test-db/$OUT"
