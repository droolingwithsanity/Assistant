#!/usr/bin/env bash
set -euo pipefail


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$REPO_ROOT/ansible"
KEY_PATH="$HOME/.ssh/id_ed25519_ai_cluster"


function banner() {
echo
echo "=============================================="
echo " ODROID-XU4 AI CLUSTER BOOTSTRAP"
echo "=============================================="
}


banner


read -rp "Which device hostname will be the MASTER (local host, e.g. ai-master)? " MASTER_NAME


# gather three nodes info
nodes=()
for i in 1 2 3; do
echo
read -rp "Enter node #$i hostname (e.g. ai-master / ai-worker-1): " host
read -rp "Enter node #$i IP address: " ip
read -rp "Enter SSH username for $host: " user
# read password silently
read -rs -p "Enter SSH password for $user@$ip (will not be stored): " pass
echo
nodes+=("$host;$ip;$user;$pass")
done


# generate key if not exists
if [[ ! -f "$KEY_PATH" ]]; then
echo "Generating ed25519 key at $KEY_PATH"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "ai-cluster"
else
echo "Using existing key at $KEY_PATH"
fi


# Install sshpass if missing (Debian/Ubuntu)
if ! command -v sshpass >/dev/null 2>&1; then
echo "sshpass not found. Installing via apt (requires sudo)."
sudo apt update && sudo apt install -y sshpass
fi


# copy key to nodes (skip master local install)
for entry in "${nodes[@]}"; do
IFS=';' read -r host ip user pass <<<"$entry"
if [[ "$host" == "$MASTER_NAME" ]]; then
echo "Skipping key copy for master ($host) — key is already local."
continue
fi
echo "Copying SSH key to $user@$ip ($host)"
# create .ssh and append public key using sshpass
PUBKEY_CONTENT=$(cat "$KEY_PATH.pub")
# use a short script to create authorized_keys remotely
sshpass -p "$pass" ssh -o StrictHostKeyChecking=no "$user@$ip" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUBKEY_CONTENT' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
echo "Key copied to $host"
done


# create ansible hosts file from template
mkdir -p "$ANSIBLE_DIR"
TEMPLATE="$ANSIBLE_DIR/hosts.ini.j2"
OUT="$ANSIBLE_DIR/hosts.ini"


MSG
