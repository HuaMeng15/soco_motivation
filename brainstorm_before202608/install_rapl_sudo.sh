#!/bin/bash
set -euo pipefail

USER_NAME="${SUDO_USER:-${USER:-$(whoami)}}"
HELPER_PATH="/usr/local/bin/read_rapl_energy"
SUDOERS_PATH="/etc/sudoers.d/rapl-energy"

echo "Installing RAPL helper for user: ${USER_NAME}"

sudo install -d -m 755 /usr/local/bin

sudo tee "${HELPER_PATH}" >/dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

case "${1:-pkg}" in
  pkg)
    exec /usr/bin/cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj
    ;;
  core)
    exec /usr/bin/cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj
    ;;
  uncore)
    exec /usr/bin/cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:1/energy_uj
    ;;
  *)
    echo "usage: read_rapl_energy [pkg|core|uncore]" >&2
    exit 2
    ;;
esac
EOF

sudo chown root:root "${HELPER_PATH}"
sudo chmod 755 "${HELPER_PATH}"

sudo tee "${SUDOERS_PATH}" >/dev/null <<EOF
${USER_NAME} ALL=(root) NOPASSWD: ${HELPER_PATH}
EOF

sudo chown root:root "${SUDOERS_PATH}"
sudo chmod 440 "${SUDOERS_PATH}"
sudo visudo -cf "${SUDOERS_PATH}"

echo
echo "Validation commands:"
echo "  sudo -n ${HELPER_PATH} pkg"
echo "  sudo -n ${HELPER_PATH} core"
echo "  sudo -n ${HELPER_PATH} uncore"
