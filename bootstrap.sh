#!/usr/bin/env bash
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
