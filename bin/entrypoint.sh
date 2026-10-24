#!/bin/sh

set -e

STARTUP_EPOCH_PATH="/tailzerotrust/.startup-epoch"

# Use the top 8 bits for WARP forwarding mark, they
# are not used by neither Tailscale nor WARP
WARP_FORWARD_MARK="0x1000000/0xff000000"

# Interface created by the WARP daemon, not configurable
WARP_DEVICE="CloudflareWARP"
WARP_DIR="/var/lib/cloudflare-warp"

warp() { warp-cli --accept-tos "$@"; }

if [ "${TG_EXPOSE_HOST:-0}" -eq 1 ]; then
  echo "Expose host to Tailscale and WARP networks"
else
  # Default to not exposing the host
  export TG_EXPOSE_HOST=0
fi

if [ -z "${TG_NAMESERVERS+set}" ]; then
  echo "Environment variable \$TG_NAMESERVERS is not set, using Cloudflare 1.1.1.1 servers"
  export TG_NAMESERVERS="1.1.1.1, 1.0.0.1"
fi

if [ -z "${WARP_CONNECT_TIMEOUT+set}" ]; then
  export WARP_CONNECT_TIMEOUT="120"
fi

# Check that the Tailscale device env variable is set
if [ -z "${TS_DEVICE+set}" ]; then
  echo "Environment variable \$TS_DEVICE is not set, defaulting to tailscale0"
  export TS_DEVICE="tailscale0"
fi

# Check that the Tailscale port env variable is set
if [ -z "${TS_PORT+set}" ]; then
  echo "Environment variable \$TS_PORT is not set, defaulting to 41641"
  export TS_PORT="41641"
fi

# https://tailscale.com/kb/1320/performance-best-practices#ethtool-configuration
NETDEV=$(ip -o -4 route show default | cut -f 5 -d " ")
[ -z "$NETDEV" ] && NETDEV=$(ip -o -6 route show default | cut -f 5 -d " ")
if [ -n "$NETDEV" ] && ethtool -k "$NETDEV" | grep -q rx-udp-gro-forwarding; then
  echo "Setting rx-udp-gro-forwarding on rx-gro-list off for device $NETDEV"
  ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off || true
fi

# Start the WARP daemon and connect it
echo "******************************"
echo "** Start Cloudflare WARP    **"
echo "******************************"

mkdir -p "${WARP_DIR}"
if [ -n "${WARP_ORGANIZATION}" ]; then
  # Zero Trust enrollment happens on its own from the MDM file
  echo "Enrolling to Zero Trust organization: ${WARP_ORGANIZATION}"
  {
    echo "<dict>"
    echo "  <key>organization</key><string>${WARP_ORGANIZATION}</string>"
    if [ -n "${WARP_AUTH_CLIENT_ID}" ]; then
      echo "  <key>auth_client_id</key><string>${WARP_AUTH_CLIENT_ID}</string>"
      echo "  <key>auth_client_secret</key><string>${WARP_AUTH_CLIENT_SECRET}</string>"
    fi
    if [ -n "${WARP_PROTOCOL}" ]; then
      echo "  <key>warp_tunnel_protocol</key><string>${WARP_PROTOCOL}</string>"
    fi
    echo "  <key>service_mode</key><string>warp</string>"
    echo "  <key>auto_connect</key><integer>1</integer>"
    echo "  <key>onboarding</key><false/>"
    echo "</dict>"
  } > "${WARP_DIR}/mdm.xml"
  chmod 600 "${WARP_DIR}/mdm.xml"
else
  rm -f "${WARP_DIR}/mdm.xml"
fi

mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system

warp-svc &
WARP_PID=$!

i=0
until warp status >/dev/null 2>&1; do
  if ! kill -0 "$WARP_PID" 2>/dev/null || [ "$i" -ge 30 ]; then
    echo "WARP daemon failed to start, exiting"
    exit 1
  fi
  sleep 1
  i=$((i + 1))
done

if [ -n "${WARP_CONNECTOR_TOKEN}" ]; then
  echo "Registering as a WARP Connector"
  warp registration show >/dev/null 2>&1 || warp connector new "${WARP_CONNECTOR_TOKEN}"
elif [ -z "${WARP_ORGANIZATION}" ]; then
  echo "Registering to consumer WARP"
  warp registration show >/dev/null 2>&1 || warp registration new
  if [ -n "${WARP_LICENSE_KEY}" ]; then
    warp registration license "${WARP_LICENSE_KEY}"
  fi
  warp mode warp
fi
warp connect >/dev/null 2>&1 || true

echo "Waiting for WARP to connect (timeout ${WARP_CONNECT_TIMEOUT}s)"
i=0
until warp status 2>/dev/null | grep -qw Connected; do
  if ! kill -0 "$WARP_PID" 2>/dev/null || [ "$i" -ge "${WARP_CONNECT_TIMEOUT}" ]; then
    echo "WARP failed to connect, exiting"
    warp status || true
    exit 1
  fi
  sleep 2
  i=$((i + 2))
done
warp status

# Docker's embedded resolver answers from the host outside the tunnel, use the
# fallback nameservers instead unless WARP has set up its own
if grep -q '^nameserver 127\.0\.0\.11' /etc/resolv.conf; then
  echo "Replacing Docker DNS resolver with: ${TG_NAMESERVERS}"
  for nameserver in $(echo "${TG_NAMESERVERS}" | tr "," "\n"); do
    if ipcalc -s -c "$nameserver"; then
      echo "nameserver $nameserver"
    else
      echo "Found an invalid nameserver \"$nameserver\", skipping..." >&2
    fi
  done > /etc/resolv.conf.new
  cat /etc/resolv.conf.new > /etc/resolv.conf
  rm -f /etc/resolv.conf.new
fi

# Find the fwmark WARP uses for its own packets, like wg-quick it routes
# everything else through its own table
WARP_FWMARK=$(ip -4 rule show | sed -n 's/.*not from all fwmark \(0x[0-9a-f]*\).*/\1/p' | head -n 1)

echo "******************************"
echo "** Setup TailGuard firewall **"
echo "******************************"

# Drop all incoming packets by default, unless localhost or required
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
iptables -A INPUT -p icmp --icmp-type parameter-problem -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -P INPUT DROP

# Create a chain for TailGuard input, dropping incoming connections
iptables -N tg-input
if [ "${TG_EXPOSE_HOST}" -eq 1 ]; then
  iptables -A tg-input -i "${WARP_DEVICE}" -j ACCEPT
  iptables -A tg-input -i "${TS_DEVICE}" -j ACCEPT
else
  # This is only for TS_DEVICE, which Tailscale accepts by default
  iptables -A tg-input -i "${TS_DEVICE}" -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A tg-input -i "${TS_DEVICE}" -j DROP
fi

# Create a chain for TailGuard forward, drop external destinations
iptables -P FORWARD DROP
iptables -N tg-forward
iptables -A tg-forward -i "${WARP_DEVICE}" ! -o "${TS_DEVICE}" -j DROP
iptables -A tg-forward -i "${TS_DEVICE}" ! -o "${WARP_DEVICE}" -j DROP
iptables -A tg-forward -i "${WARP_DEVICE}" -j MARK --set-xmark "${WARP_FORWARD_MARK}"

# Create a chain for TailGuard postrouting, masquerade packets. The
# Tailscale rules already set masquerade for Tailscale originating
# packets, so only WARP originating packets need the rule.
iptables -t nat -N tg-postrouting
iptables -t nat -A tg-postrouting -m mark --mark "${WARP_FORWARD_MARK}" -j MASQUERADE

# Drop all incoming packets by default, unless localhost or required
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j DROP
ip6tables -A INPUT -p ipv6-icmp --icmpv6-type redirect -j DROP
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -P INPUT DROP

# Create a chain for TailGuard input, dropping incoming connections
ip6tables -N tg-input
if [ "${TG_EXPOSE_HOST}" -eq 1 ]; then
  ip6tables -A tg-input -i "${WARP_DEVICE}" -j ACCEPT
  ip6tables -A tg-input -i "${TS_DEVICE}" -j ACCEPT
else
  # This is only for TS_DEVICE, which Tailscale accepts by default
  ip6tables -A tg-input -i "${TS_DEVICE}" -m state --state ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A tg-input -i "${TS_DEVICE}" -j DROP
fi

# Create a chain for TailGuard forward, drop external destinations
ip6tables -P FORWARD DROP
ip6tables -N tg-forward
ip6tables -A tg-forward -i "${WARP_DEVICE}" ! -o "${TS_DEVICE}" -j DROP
ip6tables -A tg-forward -i "${TS_DEVICE}" ! -o "${WARP_DEVICE}" -j DROP
ip6tables -A tg-forward -i "${WARP_DEVICE}" -j MARK --set-xmark "${WARP_FORWARD_MARK}"

# Create a chain for TailGuard postrouting, masquerade packets
ip6tables -t nat -N tg-postrouting
ip6tables -t nat -A tg-postrouting -m mark --mark "${WARP_FORWARD_MARK}" -j MASQUERADE

# Set PMTU discovery for both tun devices to avoid packet fragmentation
iptables -t mangle -A FORWARD -o "${WARP_DEVICE}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -o "${TS_DEVICE}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -A FORWARD -o "${WARP_DEVICE}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -A FORWARD -o "${TS_DEVICE}" -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# Add Tailscale routing table to the routing rules, since it's not
# added by our patched Tailscale. This is required to prevent the WARP
# packets getting routed back into the tailnet. The values 5270 and 52
# are hardcoded in the Tailscale source code.
if [ -n "${WARP_FWMARK}" ]; then
  echo "Setting Tailscale routing rules for WARP mark ${WARP_FWMARK}"

  # Save WARP fwmark in postrouting and restore it in prerouting
  iptables -t mangle -A POSTROUTING -p udp -m mark --mark "${WARP_FWMARK}" -j CONNMARK --save-mark
  iptables -t mangle -A PREROUTING -p udp -j CONNMARK --restore-mark
  ip6tables -t mangle -A POSTROUTING -p udp -m mark --mark "${WARP_FWMARK}" -j CONNMARK --save-mark
  ip6tables -t mangle -A PREROUTING -p udp -j CONNMARK --restore-mark

  ip -4 rule add not from all fwmark "${WARP_FWMARK}" lookup 52 pref 5270
  ip -6 rule add not from all fwmark "${WARP_FWMARK}" lookup 52 pref 5270
else
  echo "No WARP fwmark rule found, setting plain Tailscale routing rules"
  ip -4 rule add lookup 52 pref 5270
  ip -6 rule add lookup 52 pref 5270
fi

# Let Tailscale through the WARP firewall, repeated in healthcheck.sh
/tailzerotrust/healthcheck.sh warp-firewall

echo "All rules set up, waiting for healthcheck for finalisation"

echo "******************************"
echo "** Start Tailscale daemon   **"
echo "******************************"

# See https://tailscale.com/kb/1282/docker for supported parameters
export TS_ACCEPT_DNS="false"
unset TS_EXIT_NODE
export TS_AUTH_ONCE="false"
# skip TS_AUTHKEY, allow passthrough
unset TS_HEALTHCHECK_ADDR_PORT
export TS_LOCAL_ADDR_PORT="127.0.0.1:9002"
export TS_ENABLE_HEALTH_CHECK="true"
export TS_ENABLE_METRICS="false"
# skip TS_HOSTNAME, allow passthrough
export TS_KUBE_SECRET=""
unset TS_OUTBOUND_HTTP_PROXY_LISTEN
# skip TS_ROUTES, allow passthrough
unset TS_SERVE_CONFIG
unset TS_SOCKET
unset TS_SOCKS5_SERVER
export TS_STATE_DIR="/tailzerotrust/state"
export TS_USERSPACE="false"

export TS_NETMON_IGNORE="${WARP_DEVICE}"
export TS_TAILSCALED_EXTRA_ARGS="--tun=${TS_DEVICE} --port=${TS_PORT}"
TS_EXTRA_ARGS="--reset --accept-routes --advertise-exit-node"
if [ -n "${TS_LOGIN_SERVER}" ]; then TS_EXTRA_ARGS="$TS_EXTRA_ARGS --login-server=${TS_LOGIN_SERVER}"; fi
export TS_EXTRA_ARGS

# Record the startup epoch to file for reference
date +%s > "${STARTUP_EPOCH_PATH}"

echo "Starting tailscaled with args: ${TS_TAILSCALED_EXTRA_ARGS}"
echo "Starting tailscale with args: ${TS_EXTRA_ARGS}"

/usr/local/bin/containerboot
