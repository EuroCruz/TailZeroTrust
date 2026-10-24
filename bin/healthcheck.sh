#!/bin/sh

# This is a path to execute scripts on a healthy Tailscale,
# must be the same path as set in entrypoint.sh
DELAYED_SCRIPT_PATH="/tailzerotrust/.delayed-script.sh"
HEALTHY_EPOCH_PATH="/tailzerotrust/.healthy-epoch"

TS_DEVICE="${TS_DEVICE:-tailscale0}"
TS_PORT="${TS_PORT:-41641}"

iptables="${iptables:-}"
CHAIN="${CHAIN:-}"
chain="${chain:-}"

# The WARP firewall drops traffic bypassing the tunnel, which includes
# Tailscale itself (marked with 0x80000 by tailscaled). WARP rebuilds its
# table on reconnects, so the exceptions are enforced on every healthcheck.
update_warp_firewall() {
  nft list table inet cloudflare-warp >/dev/null 2>&1 || return 0
  if nft list chain inet cloudflare-warp output 2>/dev/null | grep -q tailzerotrust; then
    return 0
  fi
  echo "Enforcing Tailscale exceptions in the WARP firewall"
  nft "insert rule inet cloudflare-warp output oifname \"$TS_DEVICE\" accept comment \"tailzerotrust\""
  nft "insert rule inet cloudflare-warp output meta mark and 0xff0000 == 0x80000 accept comment \"tailzerotrust\""
  nft "insert rule inet cloudflare-warp input iifname \"$TS_DEVICE\" accept comment \"tailzerotrust\""
  nft "insert rule inet cloudflare-warp input udp dport $TS_PORT accept comment \"tailzerotrust\""
  nft "insert rule inet cloudflare-warp input ct state established,related accept comment \"tailzerotrust\""
}

if [ "$1" = "warp-firewall" ]; then
  update_warp_firewall
  exit 0
fi

update_firewall() {
  if ! $iptables -C $CHAIN -j "ts-$chain" 2>/dev/null; then
    echo "The $iptables ts-$chain rules are not set up yet, failing healthcheck"
    exit 1
  fi
  if ! $iptables -C $CHAIN -j "tg-$chain" 2>/dev/null; then
    echo "Enforcing $iptables tg-$chain rules"
    $iptables -I $CHAIN 1 -j "tg-$chain"
  fi
}

update_warp_firewall

iptables="iptables" CHAIN="INPUT" chain="input" update_firewall
iptables="iptables" CHAIN="FORWARD" chain="forward" update_firewall
iptables="iptables -t nat" CHAIN="POSTROUTING" chain="postrouting" update_firewall
iptables="ip6tables" CHAIN="INPUT" chain="input" update_firewall
iptables="ip6tables" CHAIN="FORWARD" chain="forward" update_firewall
iptables="ip6tables -t nat" CHAIN="POSTROUTING" chain="postrouting" update_firewall

# Check WARP is connected
if ! warp-cli --accept-tos status 2>/dev/null | grep -qw Connected; then
  echo "WARP is not connected"
  rm -f "${HEALTHY_EPOCH_PATH}"
  exit 1
fi

# Check Tailscale health using the health check endpoint
HEALTHZ_CODE="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:9002/healthz")"
echo "Tailscale health endpoint returned response code: ${HEALTHZ_CODE}"
if [ "$HEALTHZ_CODE" != "200" ]; then
  # The system is not healthy, delete epoch if present
  rm -f "${HEALTHY_EPOCH_PATH}"
  exit 1
fi

# Record the healthy epoch to file for reference
if [ ! -f "${HEALTHY_EPOCH_PATH}" ]; then
  date +%s > "${HEALTHY_EPOCH_PATH}"
fi

# Run delayed script if present, generally created by entrypoint.sh.
# Atomically claim it via mv so overlapping healthchecks can't double-run.
RUNNING_SCRIPT_PATH="${DELAYED_SCRIPT_PATH}.running"
if mv "${DELAYED_SCRIPT_PATH}" "${RUNNING_SCRIPT_PATH}" 2>/dev/null; then
  echo "Executing delayed script on a healthy Tailscale:"
  while IFS= read -r line; do
    [ -n "$line" ] && echo "[#] $line"
  done < "${RUNNING_SCRIPT_PATH}"

  if sh "${RUNNING_SCRIPT_PATH}"; then
    rm -f "${RUNNING_SCRIPT_PATH}"
  else
    echo "Delayed script failed, leaving it in place for retry"
    mv "${RUNNING_SCRIPT_PATH}" "${DELAYED_SCRIPT_PATH}"
  fi
fi
