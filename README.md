# TailZeroTrust

A simple Docker container app which turns the official Cloudflare WARP client
into a Tailscale exit node. Select it as the exit node on any device in your
tailnet and its traffic goes out through Cloudflare WARP or your Cloudflare
Zero Trust organization.

TailZeroTrust is a fork of [TailGuard](https://github.com/juhovh/tailguard),
with the WireGuard tunnel replaced by the Cloudflare WARP daemon.

The network topology will look roughly like this:
```
  +---------+
  | device1 |\
  +---------+ \                        VPS
  +---------+  \ +-----------+    +---------------+    +----------------+
  | device2 |----| Tailscale |<-->| TailZeroTrust |<-->| Cloudflare     |
  +---------+  / +-----------+    +---------------+    | WARP/Zero Trust|
  +---------+ /                                        +----------------+
  | device3 |/
  +---------+
```

## Benefits

Why would you want to do this? For most use cases it may be easier to run the
WARP client on your devices directly, but there are a couple of benefits with
this bridged approach:
- the device enrollment and credentials are stored only on a single machine
- devices that can't run WARP, or where you don't want to install it, can still
  use Cloudflare Gateway policies by selecting an exit node
- it's easier to switch between exit nodes in your tailnet, without having to
  reconnect to different VPNs
- you can have access to both your tailnet and WARP concurrently on your
  mobile device, which doesn't support multiple VPNs
- you can temporarily share access to WARP with other people using Tailscale,
  without having to enroll their devices

## Installation

The simplest way to start TailZeroTrust is with consumer WARP, which needs no
account at all:

```
docker network create --ipv6 ip6net
docker run -it \
  -v ./state:/tailzerotrust/state -v ./warp:/var/lib/cloudflare-warp \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  --network ip6net -p 41641:41641/udp \
  --name tailzerotrust ghcr.io/eurocruz/tailzerotrust:latest
```

Docker will print you an URL where you need to log in to your tailnet, and after
that you should be good to go. Approve the exit node in the Tailscale admin
console, select it on your device and visit <https://www.cloudflare.com/cdn-cgi/trace>,
which should show `warp=on` (or `warp=plus`).

If you want to build the latest version of the image yourself, it might be best
to use `docker compose`. In that case build the latest image with
`docker compose build` and finally run it with `docker compose up`.

That's it, happy networking!

### Cloudflare Zero Trust

To enroll the container into your Zero Trust organization without a browser,
create a service token in **Access → Service Auth**, allow it to enroll devices
in **Settings → WARP Client → Device enrollment permissions** (a rule with the
*Service Auth* action), and pass it in:

```
    environment:
      - WARP_ORGANIZATION=your-team-name
      - WARP_AUTH_CLIENT_ID=xxxxxxxx.access
      - WARP_AUTH_CLIENT_SECRET=xxxxxxxx
```

Alternatively you can register it as a
[WARP Connector](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/warp-connector/)
with `WARP_CONNECTOR_TOKEN`.

The Split Tunnels settings of the device profile still apply. The default
exclude list contains `100.64.0.0/10`, which is fine: TailZeroTrust routes the
tailnet itself and sends everything forwarded from it into WARP.

### Advanced settings

Supported configuration parameters through environment:
- `TG_EXPOSE_HOST` - Set to 1 if you want to allow connections from TS and WARP peers
- `TG_NAMESERVERS` - Nameservers to use if WARP leaves the Docker resolver in place (**default:** Cloudflare 1.1.1.1)
- `WARP_ORGANIZATION` - Zero Trust team name, consumer WARP is used if not set
- `WARP_AUTH_CLIENT_ID` - Zero Trust service token client ID for enrollment
- `WARP_AUTH_CLIENT_SECRET` - Zero Trust service token client secret for enrollment
- `WARP_CONNECTOR_TOKEN` - Register as a WARP Connector with the given token instead
- `WARP_PROTOCOL` - Tunnel protocol for Zero Trust, `wireguard` or `masque` (**default:** from device profile)
- `WARP_LICENSE_KEY` - WARP+ license key for consumer WARP
- `WARP_CONNECT_TIMEOUT` - Seconds to wait for WARP to connect (**default:** 120)
- `TS_DEVICE` - Tailscale device name, must be a valid device name (**default:** tailscale0)
- `TS_PORT` - Tailscale port number, should be exposed by Docker (**default:** 41641)
- `TS_LOGIN_SERVER` - URL of the control server if not using Tailscale default
- `TS_AUTHKEY` - Tailscale auth key for authentication if used
- `TS_HOSTNAME` - Tailscale hostname for this device if used
- `TS_ROUTES` - Set routes to advertise in addition to the exit node

Some of these parameteres follow the naming of Tailscale Docker image
[parameters](https://tailscale.com/kb/1282/docker), in which case they should
also work the same way.

### How it works

The WARP daemon routes everything that is not marked with its own fwmark
through the `CloudflareWARP` interface, much like `wg-quick` does. On top of
that, it installs an nftables firewall which drops traffic bypassing the tunnel.

- The patched Tailscale from TailGuard doesn't take over the default routes,
  and ignores the `CloudflareWARP` interface.
- Tailscale's own packets carry the `0x80000` mark, so they keep using the
  regular network, while the healthcheck keeps exceptions for them in the WARP
  firewall (WARP rebuilds it on reconnects).
- Packets forwarded from the tailnet may only leave through `CloudflareWARP`:
  if WARP is down, nothing is forwarded at all.
- Only `warp-svc` and `warp-cli` are taken from the official package, which
  otherwise depends on a full desktop stack. As WARP is built against glibc,
  the image is based on Debian instead of Alpine.

### Updates

`.github/workflows/update.yml` checks for new Tailscale and Cloudflare WARP
releases every six hours. When either is out, it bumps the version in the
Dockerfile, tags the commit as `<tailscale>-warp<warp>`, publishes the image
for `amd64` and `arm64` and creates a GitHub release. The image is also rebuilt
daily from `main` to pick up Debian security updates.
