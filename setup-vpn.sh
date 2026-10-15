#!/usr/bin/env bash
#
# setup-vpn.sh: end-to-end OpenVPN server setup for a fresh VPS.
#
# Installs OpenVPN and Easy-RSA, builds the PKI, writes the server config,
# turns on IP forwarding and NAT, starts the service, and writes a
# self-contained client profile (.ovpn) you can import on a router.
#
# Supports Rocky/Alma/CentOS Stream/RHEL 8+ and Debian 11+/Ubuntu 20.04+.
# Safe to re-run: an existing PKI is reused, so issued client profiles keep working.

set -euo pipefail

# ---- Settings (override with env vars, e.g. PROTO=udp PORT=443 bash setup-vpn.sh) ----
PROTO="${PROTO:-tcp}"            # tcp | udp
PORT="${PORT:-1194}"
CLIENT="${CLIENT:-client1}"      # name of the first client profile
PUBLIC_IP="${PUBLIC_IP:-}"       # address clients connect to; auto-detected if empty
DNS1="${DNS1:-8.8.8.8}"
DNS2="${DNS2:-8.8.4.4}"
VPN_NET="${VPN_NET:-10.8.0.0}"   # VPN subnet, always a /24
OUT_DIR="${OUT_DIR:-/root}"      # where .ovpn files are written

SERVER_DIR=/etc/openvpn/server
EASYRSA_DIR=/etc/openvpn/easy-rsa
CLIENT_TEMPLATE="$SERVER_DIR/client-common.txt"
NAT_UNIT=/etc/systemd/system/openvpn-nat.service

# Ten-year certs and CRL, so the router doesn't silently stop connecting later.
export EASYRSA_BATCH=1
export EASYRSA_CA_EXPIRE=3650
export EASYRSA_CERT_EXPIRE=3650
export EASYRSA_CRL_DAYS=3650

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage (as root):
  bash setup-vpn.sh                      install the server and the first client profile
  bash setup-vpn.sh add-client NAME      issue another client profile
  bash setup-vpn.sh revoke-client NAME   revoke a client so it can no longer connect

Settings (env vars): PROTO (tcp|udp, default tcp), PORT (1194), CLIENT (client1),
PUBLIC_IP (auto), DNS1/DNS2 (8.8.8.8/8.8.4.4), VPN_NET (10.8.0.0), OUT_DIR (/root)
EOF
  exit 1
}

easyrsa() { (cd "$EASYRSA_DIR" && ./easyrsa "$@"); }

pm_install() {
  if [[ $OS == rhel ]]; then
    "$(command -v dnf || command -v yum)" install -y "$@"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  fi
}

detect_os() {
  local ids
  ids=$(. /etc/os-release && echo "$ID ${ID_LIKE:-}")
  case "$ids" in
    *rhel*|*fedora*|*centos*) OS=rhel ;;
    *debian*|*ubuntu*)        OS=debian ;;
    *) die "Unsupported OS ($ids). Use a RHEL-family or Debian-family distro." ;;
  esac
}

preflight() {
  [[ $PROTO == tcp || $PROTO == udp ]] || die "PROTO must be tcp or udp."
  [[ $PORT =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "PORT must be 1-65535."
  [[ $VPN_NET =~ ^[0-9]+\.[0-9]+\.[0-9]+\.0$ ]] || die "VPN_NET must look like 10.8.0.0."
  validate_name "$CLIENT"

  [[ -e /dev/net/tun ]] || modprobe tun 2>/dev/null || true
  [[ -e /dev/net/tun ]] || die "TUN device unavailable. Enable TUN/TAP in your VPS control panel."

  WAN_IF=$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [[ -n $WAN_IF ]] || die "Couldn't find the default network interface."
}

validate_name() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || die "Client name '$1' may only contain letters, digits, - and _."
}

# openvpn and easy-rsa come from EPEL on RHEL-family systems. Rocky/Alma ship
# epel-release in their own repos; RHEL and many provider images don't.
enable_epel() {
  local id el
  id=$(. /etc/os-release && echo "$ID")
  el=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
  pm_install epel-release && return
  if [[ $id == ol ]]; then
    pm_install "oracle-epel-release-el$el" && return
  fi
  log "epel-release isn't in this system's repos; installing it from the Fedora project"
  pm_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$el.noarch.rpm" \
    || die "Couldn't enable EPEL, which provides openvpn and easy-rsa."
}

install_packages() {
  log "Installing packages"
  if [[ $OS == rhel ]]; then
    enable_epel
  else
    apt-get update
  fi
  pm_install openvpn easy-rsa curl

  if ! systemctl is-active --quiet firewalld && ! command -v iptables >/dev/null; then
    pm_install iptables-nft || pm_install iptables
  fi

  local ver
  ver=$(openvpn --version | awk 'NR == 1 {print $2}')
  [[ $(printf '%s\n' 2.5.0 "$ver" | sort -V | head -n1) == 2.5.0 ]] \
    || die "OpenVPN $ver is too old (need 2.5+). Use a newer OS image."
}

detect_public_ip() {
  [[ -n $PUBLIC_IP ]] && return
  PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me || true)
  if [[ ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP=$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4, a, "/"); print a[1]; exit}')
  fi
  [[ -n $PUBLIC_IP ]] || die "Couldn't detect the public IP. Re-run with PUBLIC_IP=x.x.x.x."
  log "Public IP: $PUBLIC_IP"
}

install_crl() {
  cp "$EASYRSA_DIR/pki/crl.pem" "$SERVER_DIR/crl.pem"
  # OpenVPN re-reads the CRL on every connection after dropping to nobody.
  chown "nobody:$NOGROUP" "$SERVER_DIR/crl.pem"
  chmod 644 "$SERVER_DIR/crl.pem"
  chmod o+x "$SERVER_DIR"
}

setup_pki() {
  if [[ -f $EASYRSA_DIR/pki/ca.crt && -f $EASYRSA_DIR/pki/issued/server.crt ]]; then
    log "Reusing existing PKI in $EASYRSA_DIR"
  else
    log "Building PKI (CA and server certificate)"
    local src
    src=$(find /usr/share/easy-rsa -maxdepth 2 -name easyrsa \( -type f -o -type l \) | sort -V | tail -n1)
    [[ -n $src ]] || die "easyrsa not found under /usr/share/easy-rsa."
    rm -rf "$EASYRSA_DIR"
    mkdir -p "$EASYRSA_DIR"
    cp -r "$(dirname "$src")"/. "$EASYRSA_DIR"/
    easyrsa init-pki
    EASYRSA_REQ_CN="OpenVPN CA" easyrsa build-ca nopass
    easyrsa build-server-full server nopass
    easyrsa gen-crl
  fi

  mkdir -p "$SERVER_DIR"
  cp "$EASYRSA_DIR/pki/ca.crt" "$EASYRSA_DIR/pki/issued/server.crt" "$SERVER_DIR"/
  install -m 600 "$EASYRSA_DIR/pki/private/server.key" "$SERVER_DIR/server.key"
  install_crl

  # tls-crypt hides the server from port scanners and drops unauthenticated packets early.
  if [[ ! -f $SERVER_DIR/tc.key ]]; then
    openvpn --genkey secret "$SERVER_DIR/tc.key" 2>/dev/null || openvpn --genkey --secret "$SERVER_DIR/tc.key"
    chmod 600 "$SERVER_DIR/tc.key"
  fi
}

write_configs() {
  log "Writing server config"
  cat > "$SERVER_DIR/server.conf" <<EOF
port $PORT
proto $PROTO
dev tun
topology subnet
server $VPN_NET 255.255.255.0
ca ca.crt
cert server.crt
key server.key
dh none
tls-crypt tc.key
crl-verify crl.pem
tls-version-min 1.2
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS1"
push "dhcp-option DNS $DNS2"
keepalive 10 120
user nobody
group $NOGROUP
persist-key
persist-tun
verb 3
EOF
  [[ $PROTO == udp ]] && echo "explicit-exit-notify 1" >> "$SERVER_DIR/server.conf"

  touch "$SERVER_DIR/ipp.txt"
  chown "nobody:$NOGROUP" "$SERVER_DIR/ipp.txt"

  # Shared part of every client profile; add-client appends the per-client keys.
  # ignore-unknown-option lets OpenVPN 2.4 routers load the profile and negotiate GCM anyway.
  cat > "$CLIENT_TEMPLATE" <<EOF
client
dev tun
proto $PROTO
remote $PUBLIC_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
ignore-unknown-option data-ciphers
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
tls-version-min 1.2
verb 3
EOF
}

setup_forwarding() {
  log "Enabling IPv4 forwarding"
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
  sysctl -q -w net.ipv4.ip_forward=1
}

setup_firewall() {
  local net="$VPN_NET/24"

  if systemctl is-active --quiet firewalld; then
    log "Configuring firewalld"
    firewall-cmd --permanent --query-port="$PORT/$PROTO" >/dev/null \
      || firewall-cmd --permanent --add-port="$PORT/$PROTO"
    firewall-cmd --permanent --zone=trusted --query-source="$net" >/dev/null \
      || firewall-cmd --permanent --zone=trusted --add-source="$net"
    firewall-cmd --permanent --direct --query-rule ipv4 nat POSTROUTING 0 -s "$net" ! -d "$net" -o "$WAN_IF" -j MASQUERADE >/dev/null \
      || firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "$net" ! -d "$net" -o "$WAN_IF" -j MASQUERADE
    firewall-cmd --reload
  else
    # No firewalld: manage the rules with a small unit instead of turning on a
    # firewall that could lock out SSH.
    log "Configuring iptables NAT rules ($NAT_UNIT)"
    local ipt
    ipt=$(command -v iptables)
    # Stop first so the old unit's ExecStop removes the old rules.
    systemctl stop openvpn-nat 2>/dev/null || true
    cat > "$NAT_UNIT" <<EOF
[Unit]
Description=NAT and firewall rules for OpenVPN
Before=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ipt -t nat -A POSTROUTING -s $net ! -d $net -o $WAN_IF -j MASQUERADE
ExecStart=$ipt -I INPUT -p $PROTO --dport $PORT -j ACCEPT
ExecStart=$ipt -I FORWARD -s $net -j ACCEPT
ExecStart=$ipt -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ipt -t nat -D POSTROUTING -s $net ! -d $net -o $WAN_IF -j MASQUERADE
ExecStop=$ipt -D INPUT -p $PROTO --dport $PORT -j ACCEPT
ExecStop=$ipt -D FORWARD -s $net -j ACCEPT
ExecStop=$ipt -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now openvpn-nat
  fi

  if [[ $OS == rhel && $PORT != 1194 ]] && command -v getenforce >/dev/null && [[ $(getenforce) != Disabled ]]; then
    log "Allowing port $PORT/$PROTO in SELinux"
    command -v semanage >/dev/null || pm_install policycoreutils-python-utils
    semanage port -a -t openvpn_port_t -p "$PROTO" "$PORT" 2>/dev/null \
      || semanage port -m -t openvpn_port_t -p "$PROTO" "$PORT"
  fi
}

start_server() {
  # A setup from the old manual notes would hold the same port.
  if systemctl is-active --quiet openvpn@server; then
    warn "Stopping and disabling the old openvpn@server service"
    systemctl disable --now openvpn@server
  fi

  log "Starting openvpn-server@server"
  systemctl enable openvpn-server@server >/dev/null
  systemctl restart openvpn-server@server
  if ! systemctl is-active --quiet openvpn-server@server; then
    journalctl -u openvpn-server@server -n 30 --no-pager >&2 || true
    die "OpenVPN failed to start (log above)."
  fi
}

make_client() {
  local name=$1 out="$OUT_DIR/$1.ovpn"
  validate_name "$name"
  [[ -f $CLIENT_TEMPLATE ]] || die "Server isn't installed yet. Run 'bash setup-vpn.sh' first."

  if [[ ! -f $EASYRSA_DIR/pki/issued/$name.crt ]]; then
    log "Issuing certificate for $name"
    easyrsa build-client-full "$name" nopass
  fi

  mkdir -p "$OUT_DIR"
  (
    umask 077
    {
      cat "$CLIENT_TEMPLATE"
      echo "<ca>";        cat "$EASYRSA_DIR/pki/ca.crt";                                                          echo "</ca>"
      echo "<cert>";      sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$EASYRSA_DIR/pki/issued/$name.crt";    echo "</cert>"
      echo "<key>";       cat "$EASYRSA_DIR/pki/private/$name.key";                                               echo "</key>"
      echo "<tls-crypt>"; sed -n '/BEGIN OpenVPN Static key/,/END OpenVPN Static key/p' "$SERVER_DIR/tc.key";    echo "</tls-crypt>"
    } > "$out"
  )
  log "Client profile written to $out"
  CLIENT_FILE=$out
}

revoke_client() {
  local name=$1
  validate_name "$name"
  [[ -f $EASYRSA_DIR/pki/issued/$name.crt ]] || die "No active client named '$name'."
  easyrsa revoke "$name"
  easyrsa gen-crl
  install_crl
  rm -f "$OUT_DIR/$name.ovpn"
  log "Revoked $name. It can't reconnect; a live session ends at the next renegotiation (within an hour)."
}

print_summary() {
  local ip
  ip=$(awk '$1 == "remote" {print $2}' "$CLIENT_TEMPLATE")
  cat <<EOF

  VPN server: $(awk '$1 == "proto" {print $2}' "$CLIENT_TEMPLATE") $ip:$(awk '$1 == "remote" {print $3}' "$CLIENT_TEMPLATE")
  Client profile: $CLIENT_FILE

  Copy it to your computer (run this on your computer, not the VPS):
    scp root@$ip:$CLIENT_FILE ~/Documents/

  Then import it on the router (OpenVPN client page -> upload .ovpn).
  If it can't connect, check that your VPS provider's firewall/security group
  also allows this port.

EOF
}

main() {
  [[ $EUID -eq 0 ]] || die "Run as root (sudo bash setup-vpn.sh)."
  detect_os
  NOGROUP=$(id -gn nobody)

  case "${1:-install}" in
    install)
      [[ $# -le 1 ]] || usage
      preflight
      install_packages
      detect_public_ip
      setup_pki
      write_configs
      setup_forwarding
      setup_firewall
      start_server
      make_client "$CLIENT"
      print_summary
      ;;
    add-client)
      [[ $# -eq 2 ]] || usage
      make_client "$2"
      print_summary
      ;;
    revoke-client)
      [[ $# -eq 2 ]] || usage
      revoke_client "$2"
      ;;
    *) usage ;;
  esac
}

main "$@"
