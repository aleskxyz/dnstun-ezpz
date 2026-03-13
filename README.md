## dnstun-ezpz – Easy DNS tunnel (transport) + WARP cluster

`dnstun-ezpz.sh` is a bash script that provisions a **secure, WARP‑backed cluster** where **everything runs inside Docker containers**:

- **DNS load balancer**: `dns-lb` container
- **Transport per domain**: `dnstt` or `slipstream` (one container per front domain)
- **WARP outbound**: Cloudflare WARP (via WireGuard + sing-box) for all tunnel traffic
- **Protocol per domain** (what clients use after the transport):
  - `ssh` – SSH tunnel via a locked-down user account
  - `socks` – SOCKS5 proxy via sing-box (same username/password as SSH for authentication)
- **Multi-domain support** in a single deployment

All generated configs live under `/opt/dnstun-ezpz` on the host.

The script **must be run as root**.

**راهنمای استفاده به فارسی:** [GUIDE_FA.md](GUIDE_FA.md)

---

## 1. First-time deployment (create cluster)

### 1.1. Run via jsDelivr

On a **fresh server**, do:

```bash
sudo -i
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh")
```

On first run (no existing config under `/opt/dnstun-ezpz`), it will go straight into **Create cluster**.

### 1.2. Prompts

You will be asked:

1. **This server's ID** (1–255)

   Unique ID for this machine. It must match the subdomain number: server ID `1` → hostname `s1.example.com`, ID `2` → `s2.example.com`, etc. Used by the DNS load balancer and by slipstream (`--quic-lb-server-id`). Each server in the cluster must have a distinct ID.

2. **Prefix for server domain names** (default `s`)

   Used to build backend hostnames for DNS records:

   ```text
   s1.example.com
   s2.example.com
   s3.example.com
   ```

3. **Number of servers** (default `3`)

   Logical count of backends in the DNS LB. This controls:

   - Number of backend IDs (`s1`, `s2`, …) per pool.

4. **Username** (default `vpnuser`)

   - Used for SSH tunnel login and SOCKS proxy authentication.
   - Script will create the system user if it doesn’t exist.

5. **Password**

   - Password for the username above (used by clients for SSH and SOCKS).

6. **Number of domains** (at least `1`)

   Example: `2` for `ns1.example.com` and `ns2.example.com`.

7. For each domain:

   - **Domain name** (e.g. `ns1.example.com`)
   - **Transport** (dnstt or slipstream): DNS tunnel implementation for this domain
   - **Protocol** (ssh or socks):
     - `ssh`  → transport → sshd → `vpnuser`
     - `socks` → transport → sing-box SOCKS5 proxy on `127.0.0.1:2030`

8. **DNSTT private key** (only if at least one domain uses dnstt)

   - You are asked for the DNSTT private key (64 hex characters).
   - **Leave empty** to keep the current key (when reconfiguring) or to **generate a new key** (when creating or if none exists).
   - If you paste a key, the script verifies it by deriving the public key; invalid keys are rejected and you are re-prompted.
   - If you later reconfigure to **slipstream-only** (no dnstt domains), the stored private key is **kept as-is** in the config (not removed).

Invalid input for any prompt is rejected; the previous or default value is kept and you are asked again.

### 1.3. What you see at the end

After answering the prompts, the script brings up / updates all Docker services and then prints:

- **Client config per instance** (domain, transport, protocol, username/password, and for dnstt the public key)
- **SlipNet URI** (`slipnet://…`) for each instance — paste or scan to import into the [SlipNet](https://github.com/AnonVector/SlipNet) app
- **QR code** for each instance — scan directly with the SlipNet app's camera
- **DNS records to create** (A + NS)
- A **join command** you can copy to other servers to join the same cluster.

---

## 3. DNS configuration

Assume:

- Base zone: `example.com`
- Domains:
  - `ns1.example.com`
  - `ns2.example.com`

The script prints two sets of records you must create:

### 3.1. A records (base zone)

In `example.com` zone. Each record corresponds to one server ID (e.g. `s1` = server id 1, `s2` = server id 2):

```text
s1.example.com  A  <server-1-public-ip>   [server id: 1]
s2.example.com  A  <server-2-public-ip>   [server id: 2]
...
```

### 3.2. NS records (per front domain)

For each front domain:

```text
ns1.example.com  NS  s1.example.com.
ns1.example.com  NS  s2.example.com.

ns2.example.com  NS  s1.example.com.
ns2.example.com  NS  s2.example.com.
```

These NS records go in the parent zone of each `nsX.example.com` (e.g. `example.com`).

---

## 4. Joining additional servers

At the end of a successful run on the **first server**, you get a join command like:

```bash
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh") "<BASE64_JOIN_CONFIG>"
```

To join another server:

1. SSH into the second server as **root**.
2. Run that exact command.

The script will:

- Decode the join JSON from the base64 string.
- **Ask for this server's ID (1–255).** If this machine already has a config under `/opt/dnstun-ezpz`, the existing server ID is offered as the default; you can press Enter to keep it or enter a different ID. Each server in the cluster must have a distinct ID that matches its subdomain (e.g. second server → ID `2` → `s2.example.com`).
- Recreate all necessary configs under `/opt/dnstun-ezpz`.
- Bring up the same services on the new server.
- Restart docker/sshd **once** if needed.
- Print client/DNS/join info again.

---

## 5. Single-server with multiple protocols / domains

You can use **one server** to serve multiple domains, each with its own protocol (ssh or socks).

### 5.1. Example: two SSH domains

Run:

```bash
sudo -i
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh")
```

Choose:

- **This server's ID** = `1`
- `PREFIX = s`
- `NUM_SERVERS = 1`
- Username = `vpnuser`
- `NUM_DOMAINS = 2`
- Domain #1: `ns1.example.com`, transport `dnstt` (or `slipstream`), protocol `ssh`
- Domain #2: `ns2.example.com`, transport `dnstt` (or `slipstream`), protocol `ssh`

Result:

- Both `ns1` and `ns2` resolve to your server.
- Each is a separate transport pool (dnstt or slipstream) but both use protocol SSH on your server.
- Clients can pick any domain; both reach the same `vpnuser` account.

### 5.2. Example: SSH + SOCKS in one deployment

Same steps, but:

- Domain #1: `ns1.example.com`, transport (e.g. dnstt), protocol `ssh`
- Domain #2: `ns2.example.com`, transport (e.g. dnstt), protocol `socks`

Result:

- `ns1.example.com` → transport → sshd → `vpnuser` (SSH tunnel).
- `ns2.example.com` → transport → sing-box SOCKS5.
- Both use the **same WARP** outbound so traffic doesn’t leave via your real IP.

---

## 6. Security model

### 6.1. Dedicated SSH user

The script uses a **separate SSH user** (default `vpnuser`) and installs:

```sshconfig
Match User vpnuser Address 127.0.0.1
    PasswordAuthentication yes
    AllowTcpForwarding local
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    GatewayPorts no
    ForceCommand echo 'TCP forwarding only'
```

This means:

- That user:
  - **Cannot** get a normal shell.
  - **Cannot** bind remote ports or gateways.
  - **Can only** do local TCP forwarding from localhost.

Traffic from this user is then routed and/or proxied over WARP.

### 6.2. WARP as outbound

- The script creates or reuses a WARP account via `wgcf`.
- It configures sing-box with that WARP interface as **final outbound**:
  - SOCKS5 connections → WARP
  - SSH tunnels for `vpnuser` are routed through `route_setup.sh` to `wg0`.
- Your server’s real IP is **not the exit IP** for tunneled traffic.

This helps protect the **server owner**:

- If users abuse the VPN / tunnel, traffic appears to exit from WARP, not your host.
- You have a constrained SSH account just for tunneling, separate from real logins.

### 6.3. Config-change safety
> Internally the script tracks config changes and only restarts services when needed. You don’t need to think about this; just re-run the script to update the deployment.

---

## 7. Managing an existing deployment

When there is an existing `dnstun.conf` and you run:

```bash
sudo -i
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.2.0/dnstun-ezpz.sh")
```

You see:

```text
Select action:
1) Print current config
2) Reconfigure cluster
3) Start services
4) Stop services
5) Restart services
6) Uninstall cluster
```

### 7.1. Print current config (1)

Prints:

- **This server's ID** (1–255).
- **Per instance**:
  - Domain, **transport** (dnstt / slipstream), **protocol** (`ssh` / `socks`)
  - Username/password (same for SSH and SOCKS)
  - Public key (only for dnstt; slipstream uses TLS)
  - **SlipNet URI** (`slipnet://…`) — import into the SlipNet app by pasting
  - **QR code** — scan with the SlipNet app to import the profile
- **DNS records** (A + NS, with server id indicated for each A record).
- **Join command** for other servers.

### 7.2. Reconfigure (2)

- Lets you change this server's ID (1–255), prefix, server count, username/password, domains, transports, and protocols.
- If any domain uses **dnstt**, you are prompted for the DNSTT private key (leave empty to keep current or generate new).
- If you switch to **slipstream-only** (no dnstt), the existing private key remains in the config; it is not removed.
- Regenerates all configs and refreshes the Docker deployment.
- You have to run the join command again on all other servers after change.

### 7.3. Start / stop / restart (3–5)

- **3 – Start**: start all containers for the cluster.
- **4 – Stop**: stop all containers for the cluster (without removing them).
- **5 – Restart**: fully restart all containers for the cluster.

### 7.4. Uninstall (6)

- Stops and removes all cluster containers.
- Deletes the WARP account and tunnel user that were created for the cluster.
- Removes `/opt/dnstun-ezpz` and all generated config files.

---

