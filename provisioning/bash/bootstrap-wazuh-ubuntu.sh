#!/usr/bin/env bash
# SecretCon 2026 — Wazuh SIEM bootstrap
# Runs as root via Packer shell provisioner on Ubuntu 22.04.

set -euo pipefail

WAZUH_VERSION="${WAZUH_VERSION:-4.14}"
WAZUH_PATCH="${WAZUH_PATCH:-4.14.5}"
WAZUH_INSTALL_SHA256="${WAZUH_INSTALL_SHA256:-5ca5d3b605642b15935a6efdea731a6113a4a838a13caf71d2dd4a8feb32d69f}"
INSTALL_DIR="/root/wazuh-install"

echo "[*] Expanding root partition and filesystem (Proxmox qm resize)"
if command -v growpart &>/dev/null; then
  growpart /dev/sda 1 || true
  resize2fs /dev/sda1 || true
  echo "[*] Partition expanded. Disk now:"
  df -h /
else
  echo "[!] growpart not available, skipping partition expansion"
fi

echo "[*] apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get -o Dpkg::Options::="--force-confnew" -y upgrade

echo "[*] Fetching wazuh-install.sh (${WAZUH_PATCH})"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"
curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh"
chmod +x wazuh-install.sh

echo "[*] Verifying installer SHA256"
echo "${WAZUH_INSTALL_SHA256}  wazuh-install.sh" | sha256sum --check --strict || {
  echo "ERROR: wazuh-install.sh checksum mismatch" >&2
  echo "Expected: ${WAZUH_INSTALL_SHA256}" >&2
  echo "Got:      $(sha256sum wazuh-install.sh | cut -d' ' -f1)" >&2
  exit 1
}

echo "[*] Running all-in-one install"
bash ./wazuh-install.sh -a -i

if [[ -f wazuh-install-files.tar ]]; then
  tar -xf wazuh-install-files.tar -C "${INSTALL_DIR}"
fi
if [[ -f "${INSTALL_DIR}/wazuh-install-files/wazuh-passwords.txt" ]]; then
  install -m 0600 "${INSTALL_DIR}/wazuh-install-files/wazuh-passwords.txt" /root/wazuh-passwords.txt
  echo "[*] Dashboard credentials saved to /root/wazuh-passwords.txt"
fi

echo "[*] Creating agent group: ews"
/var/ossec/bin/agent_groups -a -g ews -q || true

echo "[*] Adding Suricata EVE JSON remote listener (TCP/1514)"
OSSEC_CONF="/var/ossec/etc/ossec.conf"
if ! grep -q "<!-- SecretCon: Suricata EVE -->" "${OSSEC_CONF}"; then
  python3 - "${OSSEC_CONF}" <<'PY'
import sys, re
path = sys.argv[1]
with open(path) as f:
    data = f.read()
block = """
  <!-- SecretCon: Suricata EVE -->
  <remote>
    <connection>syslog</connection>
    <port>1514</port>
    <protocol>tcp</protocol>
    <allowed-ips>192.168.61.0/24</allowed-ips>
  </remote>
"""
data = re.sub(r"</ossec_config>\s*$", block + "</ossec_config>\n", data, count=1)
with open(path, "w") as f:
    f.write(data)
PY
  # Verify patch was applied
  grep -q "<!-- SecretCon: Suricata EVE -->" "${OSSEC_CONF}" || {
    echo "ERROR: Suricata EVE listener patch not applied to ossec.conf" >&2
    exit 1
  }
fi

echo "[*] Installing SecretCon Suricata local rules (86600-86604)"
cat > /var/ossec/etc/rules/local_rules.xml <<'XML'
<group name="suricata,secretcon,">
  <rule id="86600" level="3">
    <decoded_as>json</decoded_as>
    <field name="event_type">alert</field>
    <description>Suricata: alert event</description>
  </rule>
  <rule id="86601" level="7">
    <if_sid>86600</if_sid>
    <field name="alert.severity">^1$</field>
    <description>Suricata: high-severity alert</description>
  </rule>
  <rule id="86602" level="5">
    <if_sid>86600</if_sid>
    <field name="alert.severity">^2$</field>
    <description>Suricata: medium-severity alert</description>
  </rule>
  <rule id="86603" level="3">
    <if_sid>86600</if_sid>
    <field name="alert.severity">^3$</field>
    <description>Suricata: low-severity alert</description>
  </rule>
  <rule id="86604" level="10">
    <if_sid>86600</if_sid>
    <field name="alert.category">Attempted Administrator Privilege Gain</field>
    <description>Suricata: attempted privilege escalation</description>
  </rule>
</group>
XML
chown root:wazuh /var/ossec/etc/rules/local_rules.xml
chmod 0660 /var/ossec/etc/rules/local_rules.xml

echo "[*] Restarting wazuh-manager"
systemctl restart wazuh-manager
systemctl --no-pager status wazuh-manager | head -n 20

echo "[*] Verifying wazuh-manager is active"
systemctl is-active --quiet wazuh-manager || {
  echo "ERROR: wazuh-manager failed to start" >&2
  journalctl -u wazuh-manager -n 50 >&2
  exit 1
}

echo "[*] Bootstrap complete."
