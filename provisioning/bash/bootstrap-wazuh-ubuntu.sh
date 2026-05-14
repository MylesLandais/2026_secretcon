#!/usr/bin/env bash
# SecretCon 2026 — Wazuh SIEM bootstrap
# Runs as root via Packer shell provisioner on Ubuntu 22.04.

set -euo pipefail

WAZUH_VERSION="${WAZUH_VERSION:-4.8}"
INSTALL_DIR="/root/wazuh-install"

echo "[*] apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get -o Dpkg::Options::="--force-confnew" -y upgrade

echo "[*] Fetching wazuh-install.sh (${WAZUH_VERSION})"
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"
curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh"
chmod +x wazuh-install.sh

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

echo "[*] Bootstrap complete."
