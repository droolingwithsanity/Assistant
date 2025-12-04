# Assistant
AI assistant cluster
# ODROID-XU4 3-Node AI Cluster — Automated Bootstrap

This repository automates creating a production-ready 3-node ODROID-XU4 cluster. It:

* Prompts you for the 3 devices' IPs, usernames and passwords
* Creates an SSH ed25519 keypair on your controller (ai-master)
* Copies the public key to each worker using `sshpass` (passwords provided interactively)
* Generates an Ansible inventory file with the hosts you provided
* Installs Ansible (if missing) on the controller
* Runs base bootstrap Ansible playbook to install packages on all nodes
* Provides role-specific Ansible playbooks for master (UI/API) and workers (LLM / STT/TTS)

> **Security note:** The bootstrap uses `sshpass` so you can seed worker accounts with the generated SSH key. `sshpass` transmits passwords on the command line — use it only on a trusted LAN. After the keys are installed, you may remove `sshpass` and clear any saved credentials.

---

## Repo layout

```
odroid-ai-cluster-automation/
├─ bootstrap.sh                  # Main interactive script you run on ai-master
├─ README.md                     # This document
├─ ansible/
│  ├─ hosts.ini.j2               # Template inventory for bootstrap to fill
│  ├─ setup.yml                  # Base setup for all nodes
│  ├─ deploy-master.yml          # Master role deploy tasks
│  └─ deploy-workers.yml         # Workers role deploy tasks
├─ services/
│  └─ sample_master_api.sh       # Simple systemd-compatible start script for API
└─ extras/
   └─ sample_ui_repo_link.txt    # Replace with your UI repo
```

---

## How it works (high level)

1. Run `bootstrap.sh` on the device you want to act as `ai-master`.
2. The script asks you to fill in IP addresses, SSH usernames and passwords for the other machines.
3. It generates an SSH keypair (ed25519) at `~/.ssh/id_ed25519_ai_cluster` on the master.
4. It installs `sshpass` (if necessary) and copies the public key to worker nodes using `ssh-copy-id` driven by `sshpass`.
5. The script generates `ansible/hosts.ini` from the template and installs Ansible if needed.
6. It runs `ansible-playbook ansible/setup.yml` to install base packages on all nodes.
7. Optionally it runs masters/workers deployment playbooks.

---

## Quick start

1. Copy this repository to the ODROID you will use as `ai-master`.

```bash
git clone https://example.com/your-repo.git
cd odroid-ai-cluster-automation
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

2. Follow interactive prompts. After bootstrap completes, your cluster will be reachable with passwordless SSH from `ai-master` and Ansible will be configured.

---

## Files (full content)

> NOTE: The raw file contents are saved in this canvas so you can copy/paste or download. Do not paste sensitive passwords into the repo — the `bootstrap.sh` script will read them interactively and never save them to disk.

### `bootstrap.sh`

```bash
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

if [[ ! -f "$TEMPLATE" ]]; then
  cat > "$TEMPLATE" <<'EOF'
[master]
{{ master_hostname }} ansible_host={{ master_ip }} ansible_user={{ master_user }} ansible_connection=local

[workers]
{% for w in workers %}
{{ w.hostname }} ansible_host={{ w.ip }} ansible_user={{ w.user }}
{% endfor %}

[ai_cluster:children]
master
workers
EOF
fi

# render the template (simple rendering without jinja: do replacements)
master_host_entry=""
workers_entries=""

# build values from nodes array
for entry in "${nodes[@]}"; do
  IFS=';' read -r host ip user pass <<<"$entry"
  if [[ "$host" == "$MASTER_NAME" ]]; then
    master_host_entry="$host ansible_host=$ip ansible_user=$user ansible_connection=local"
  else
    workers_entries+="$host ansible_host=$ip ansible_user=$user\n"
  fi
done

cat > "$OUT" <<EOF
[master]
$master_host_entry

[workers]
$workers_entries

[ai_cluster:children]
master
workers
EOF

echo "Generated Ansible inventory at $OUT"

# install ansible if missing
if ! command -v ansible >/dev/null 2>&1; then
  echo "Installing Ansible on local host (requires sudo)..."
  sudo apt update && sudo apt install -y ansible
fi

# run base playbook
echo "Running base setup playbook: ansible/setup.yml"
ansible-playbook -i "$OUT" "$ANSIBLE_DIR/setup.yml" --ask-become-pass || true

# done message
cat <<MSG

Bootstrap complete (best effort). Next steps:
 - Review $ANSIBLE_DIR/hosts.ini and adjust if needed
 - Run: ansible-playbook -i $ANSIBLE_DIR/hosts.ini $ANSIBLE_DIR/deploy-master.yml
 - Run: ansible-playbook -i $ANSIBLE_DIR/hosts.ini $ANSIBLE_DIR/deploy-workers.yml

If anything failed, re-run the script or run individual ansible-playbook commands.
MSG
```

### `ansible/hosts.ini.j2` (template)

```ini
[master]
{{ master_hostname }} ansible_host={{ master_ip }} ansible_user={{ master_user }} ansible_connection=local

[workers]
# worker entries inserted by bootstrap script

[ai_cluster:children]
master
workers
```

### `ansible/setup.yml`

```yaml
- name: Base setup for all AI nodes
  hosts: ai_cluster
  become: yes
  vars:
    apt_packages:
      - git
      - curl
      - wget
      - build-essential
      - python3
      - python3-pip
      - python3-venv
      - ffmpeg
      - sox
      - alsa-utils
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Upgrade all packages
      apt:
        upgrade: dist

    - name: Install packages
      apt:
        name: "{{ apt_packages }}"
        state: present

    - name: Ensure ssh service running
      service:
        name: ssh
        state: started
        enabled: yes

    - name: Ensure /opt exists
      file:
        path: /opt
        state: directory
        mode: '0755'
```

### `ansible/deploy-master.yml`

```yaml
- name: Deploy UI + API Gateway on master
  hosts: master
  become: yes
  tasks:
    - name: Install Node.js and npm (from apt)
      apt:
        name:
          - nodejs
          - npm
        state: present

    - name: Clone UI repo placeholder (replace URL)
      git:
        repo: https://github.com/YOUR_UI_REPO.git
        dest: /opt/ai-ui
        update: yes
      ignore_errors: yes

    - name: Create a virtualenv for python services
      command: python3 -m venv /opt/ai-master-venv creates=/opt/ai-master-venv/bin/activate

    - name: Ensure a systemd service script exists (sample)
      copy:
        dest: /opt/ai-master-start.sh
        mode: '0755'
        content: |
          #!/usr/bin/env bash
          source /opt/ai-master-venv/bin/activate
          cd /opt/ai-ui || exit 1
          # example start, replace with your UI server command
          npm install --no-audit --no-fund
          npm run start

    - name: Create systemd service file for master API (sample)
      copy:
        dest: /etc/systemd/system/ai-master.service
        mode: '0644'
        content: |
          [Unit]
          Description=AI Master API
          After=network.target

          [Service]
          Type=simple
          User=root
          ExecStart=/opt/ai-master-start.sh
          Restart=on-failure

          [Install]
          WantedBy=multi-user.target

    - name: Reload systemd and enable service
      systemd:
        daemon_reload: yes
        name: ai-master.service
        state: started
        enabled: yes
```

### `ansible/deploy-workers.yml`

```yaml
- name: Deploy AI Workers
  hosts: workers
  become: yes
  vars:
    venv_path: /opt/ai-venv
  tasks:
    - name: Create virtualenv
      command: python3 -m venv {{ venv_path }} creates={{ venv_path }}/bin/activate

    - name: Ensure pip is upgraded
      command: {{ venv_path }}/bin/python -m pip install --upgrade pip

    - name: Install typical AI packages into venv
      pip:
        virtualenv: "{{ venv_path }}"
        name:
          - flask
          - uvicorn
          - faster-whisper
          - openai
        state: present

    - name: Create worker start script (sample)
      copy:
        dest: /opt/ai-worker-start.sh
        mode: '0755'
        content: |
          #!/usr/bin/env bash
          source {{ venv_path }}/bin/activate
          # replace the following with your worker command
          exec python3 -m flask run --host=0.0.0.0 --port=8000

    - name: Create systemd service for worker
      copy:
        dest: /etc/systemd/system/ai-worker.service
        mode: '0644'
        content: |
          [Unit]
          Description=AI Worker Service
          After=network.target

          [Service]
          Type=simple
          User=root
          ExecStart=/opt/ai-worker-start.sh
          Restart=on-failure

          [Install]
          WantedBy=multi-user.target

    - name: Reload systemd and enable worker service
      systemd:
        daemon_reload: yes
        name: ai-worker.service
        state: started
        enabled: yes
```

### `services/sample_master_api.sh`

```bash
#!/usr/bin/env bash
# Example master startup wrapper. Replace with real UI/API start command.
source /opt/ai-master-venv/bin/activate
cd /opt/ai-ui || exit 1
npm install --no-audit --no-fund
npm run start
```

### `extras/sample_ui_repo_link.txt`

```
# Replace this with the git URL of your chat UI repo.
https://github.com/yourusername/ai-chat-ui
```

---

## Security & best practices

* After bootstrap, manually SSH into each node and verify `~/.ssh/authorized_keys` contains only the key you expect.
* Remove `sshpass` and any temporary password storage if security is a concern.
* Consider using a jump host if your devices will be exposed to the internet.
* Use firewalls (ufw) to only allow necessary ports on each node.
* Use strong local usernames and remove password authentication if not needed.

---

## Next steps I can do for you

* Produce a **full UI repo** (React + Tailwind + mic capture + WebSocket) ready to clone into `/opt/ai-ui`.
* Create a **sample Flask worker** that hosts an LLM API endpoint using `llama.cpp`/`ggml` or a tiny quantized model suggestion.
* Add **vector DB** and memory support (e.g. Chroma local store) and Ansible tasks for installing it.

Tell me which next step you want and I will generate it and add it to this canvas.
