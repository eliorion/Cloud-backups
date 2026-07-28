# modules/scrape-proxy.nix — HTTP/CONNECT egress proxy for the scraping system,
# reachable over the tailnet, exiting via the node's OWN residential ISP address.
#
# This is NOT the Tailscale exit-node role (fleet.proxyNode, modules/tailscale.nix).
# An exit node is selected per CLIENT and takes ALL of that client's traffic, so a
# scraper cannot use B and C concurrently or rotate per request. A plain HTTP proxy
# is addressed per REQUEST (`proxies={"https": "http://node-b…:8888"}`), which is
# what an IP-rotating scraper needs. The two are independent; this module neither
# sets nor clears fleet.proxyNode.
#
# ── STAGED behind fleet.scrapeProxy.enable (default FALSE), like fleet.netbird ──
# Off = no daemon, no listener, no behaviour change.
#
# ── NETWORK RULE (doc 00 §3/§5), same as every Garage listener ──
# Binds fleet.tailscaleIp ONLY, never 0.0.0.0 — an open proxy on the WAN address
# would be found and abused within hours. modules/base.nix already trusts
# tailscale0, so NO allowedTCPPorts entry is needed (and must not be added: that
# would open the port on the physical NIC too).
#
# ── Tailscale ACL lives in the admin console, NOT this repo ──
# Deny-by-default means the port is unreachable until granted. Add, alongside the
# existing garage rules (modules/tailscale.nix header):
#   - tag:scraper -> tag:garage  on tcp:8888   (the scraping system only)
# Do NOT widen an existing tag:k8s rule to cover this port unless the scraper truly
# is the prod cluster: tag:k8s is already granted tcp:3900 to the same hosts.
#
# ── RISK ACCEPTED BY ENABLING THIS ON B/C ──
# node-B and node-C hold the ZFS snapshot moat (modules/zfs-sanoid.nix). Enabling
# this adds an inbound service AND attacker-influenced outbound traffic to the two
# boxes holding the DR data. node-D (gateway, capacity 0, no data pool, no moat)
# carries none of that risk and is the safer host if two egress IPs suffice.
{ config, lib, ... }:
let
  cfg = config.fleet.scrapeProxy;
in
{
  options.fleet.scrapeProxy = {
    enable = lib.mkEnableOption "the tailnet-only HTTP egress proxy for the scraping system (see header)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = "TCP port for the scrape proxy on the tailscale0 address (tinyproxy default).";
    };

    connectPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 443 ];
      description = ''
        Ports the proxy will CONNECT-tunnel to. Restricting this stops the proxy being
        used as a generic outbound TCP tunnel (SMTP relay, etc.) by anything that
        reaches it. 443 covers https:// scraping; plain http:// does not use CONNECT
        and is unaffected. Add a port only if a target actually serves TLS elsewhere.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.tinyproxy = {
      enable = true;
      settings = {
        Listen = config.fleet.tailscaleIp; # overlay IP ONLY (see header)
        Port = cfg.port;
        # Second gate behind the ACL + firewall: only tailnet CGNAT sources.
        Allow = "100.64.0.0/10";
        ConnectPort = cfg.connectPorts;
        # Do NOT set `Anonymous` — it is a header WHITELIST, and anything omitted is
        # stripped. A scraper needs User-Agent/Accept-Language/Cookie/Referer to pass
        # through verbatim or targets fingerprint it. Omitting the directive entirely
        # forwards all headers (only affects plain http://; CONNECT tunnels are raw).
        DisableViaHeader = true; # no `Via:` header advertising that a proxy is in path
        Timeout = 600;
      };
    };

    # Upstream's unit has no ordering against tailscaled and no RestartSec, so at boot
    # it tries to bind fleet.tailscaleIp before tailscale0 exists, fails, and burns
    # through the default start-limit (5 starts / 10s) — leaving the proxy dead until
    # a human notices, on nodes that are offsite by design. Order it after tailscaled
    # and let it retry forever at a sane interval, mirroring modules/garage.nix.
    systemd.services.tinyproxy = {
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      unitConfig.StartLimitIntervalSec = 0; # [Unit] since systemd 229, not [Service]
      serviceConfig.RestartSec = "10s"; # upstream already sets Restart = "on-failure"
    };
  };
}
