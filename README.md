# vpn

One script that turns a fresh VPS into an OpenVPN server and produces a `.ovpn` client profile ready to import on a router.

Works on Rocky/Alma/CentOS Stream/RHEL 8+ and Debian 11+/Ubuntu 20.04+.

## Run it on the VPS

```bash
ssh root@YOUR_VPS_IP
curl -fsSLO https://raw.githubusercontent.com/thepie55/vpn/main/setup-vpn.sh
bash setup-vpn.sh
```

(or `git clone` the repo and run `bash setup-vpn.sh` inside it)

At the end it prints the path of the client profile (`/root/client1.ovpn`) and the `scp` command to copy it to your computer:

```bash
scp root@YOUR_VPS_IP:/root/client1.ovpn ~/Documents/
```

Then upload that file on the router's OpenVPN client page.

## Options

Set them as env vars in front of the command, e.g. `PROTO=udp PORT=443 bash setup-vpn.sh`.

| Variable    | Default            | Meaning                                    |
|-------------|--------------------|--------------------------------------------|
| `PROTO`     | `tcp`              | `tcp` or `udp` (udp is faster if your network allows it) |
| `PORT`      | `1194`             | Port the server listens on                 |
| `CLIENT`    | `client1`          | Name of the first client profile           |
| `PUBLIC_IP` | auto-detected      | Address written into the client profile    |
| `DNS1/DNS2` | `8.8.8.8/8.8.4.4`  | DNS servers pushed to clients              |
| `VPN_NET`   | `10.8.0.0`         | VPN subnet (/24)                           |
| `OUT_DIR`   | `/root`            | Where `.ovpn` files are written            |

## Managing clients

```bash
bash setup-vpn.sh add-client laptop       # writes /root/laptop.ovpn
bash setup-vpn.sh revoke-client laptop    # that profile can no longer connect
```

Re-running `bash setup-vpn.sh` is safe: it keeps the existing CA and keys, so profiles you already imported keep working. If you change `PROTO`, `PORT` or `PUBLIC_IP` on a re-run, regenerate the profiles with `add-client` and re-import them.

## What it does

1. Installs `openvpn`, `easy-rsa` (from EPEL on RHEL-family) and `curl`.
2. Builds a PKI in `/etc/openvpn/easy-rsa`: CA, server cert, CRL (all valid 10 years), plus a `tls-crypt` key.
3. Writes `/etc/openvpn/server/server.conf`: AES-GCM ciphers, TLS 1.2+, all client traffic routed through the VPN.
4. Enables IPv4 forwarding and NAT: through firewalld if it is running, otherwise through an `openvpn-nat` systemd unit with iptables rules. It never turns on a firewall that wasn't already running, so it can't lock you out of SSH.
5. Starts and enables `openvpn-server@server`.
6. Writes a single-file client profile with the certs and keys inline.

Your VPS provider's own firewall or security group, if it has one, must also allow the port.

## Troubleshooting

```bash
systemctl status openvpn-server@server
journalctl -u openvpn-server@server -f
```
