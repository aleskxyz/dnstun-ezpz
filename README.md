## dnstun-ezpz – Easy DNSTT + WARP cluster

`dnstun-ezpz.sh` is a bash script that provisions a **secure, WARP‑backed DNSTT cluster**, where **everything runs inside Docker containers**:

- **DNS load balancer**: `dns_tunnel_lb` container
- **DNSTT servers**: one container per front domain
- **WARP outbound**: Cloudflare WARP (via WireGuard + sing-box) for all tunnel traffic
- **Protocols per domain**:
  - `ssh` – SSH tunnel via a locked-down user account
  - `socks` – SOCKS5 proxy via sing-box
- **Multi-domain support** in a single deployment

All generated configs live under `/opt/dnstun-ezpz` on the host.

The script **must be run as root**.

---

## 1. First-time deployment (create cluster)

### 1.1. Run via jsDelivr

On a **fresh server**, do:

```bash
sudo -i
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.1.0/dnstun-ezpz.sh")
```

On first run (no existing config under `/opt/dnstun-ezpz`), it will go straight into **Create cluster**.

### 1.2. Prompts

You will be asked:

1. **Prefix for server domain names** (default `s`)

   Used to build backend hostnames for DNS records:

   ```text
   s1.example.com
   s2.example.com
   s3.example.com
   ```

2. **Number of servers** (default `3`)

   Logical count of backends in the DNS LB. This controls:

   - Number of backend IDs (`s1`, `s2`, …) per pool.

3. **SSH username** (default `vpnuser`)

   - Dedicated SSH user for tunneling.
   - Script will create it if it doesn’t exist.

4. **SSH password**

   - Password for `vpnuser` (used by clients).

5. **Number of domains** (at least `1`)

   Example: `2` for `ns1.example.com` and `ns2.example.com`.

6. For each domain:

   - **Domain name** (e.g. `ns1.example.com`)
   - **Type**:
     - `ssh`  → DNSTT → sshd → `vpnuser`
     - `socks` → DNSTT → sing-box SOCKS5 proxy on `127.0.0.1:2030`

### 2.3. What you see at the end

After answering the prompts, the script brings up / updates all Docker services and then prints:

- **Client config per instance** (domain, type, SSH user/password for `ssh` domains)
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

In `example.com` zone:

```text
s1.example.com  A  <server-1-public-ip>
s2.example.com  A  <server-2-public-ip>
...
```

### 3.2. NS records (per front domain)

For each DNSTT front domain:

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
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.1.0/dnstun-ezpz.sh") "<BASE64_JOIN_CONFIG>"
```

To join another server:

1. SSH into the second server as **root**.
2. Run that exact command.

The script will:

- Decode the join JSON from the base64 string.
- Recreate all necessary configs under `/opt/dnstun-ezpz`.
- Bring up the same services on the new server.
- Restart docker/sshd **once** if needed.
- Print client/DNS/join info again.

No prompts are shown in join mode; everything comes from the join config.

---

## 5. Single-server with multiple protocols / domains

You can use **one server** to serve multiple domains and protocols.

### 5.1. Example: two SSH domains

Run:

```bash
sudo -i
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.1.0/dnstun-ezpz.sh")
```

Choose:

- `PREFIX = s`
- `NUM_SERVERS = 1`
- `SSH_USER = vpnuser`
- `NUM_DOMAINS = 2`
- Domain #1: `ns1.example.com`, type `ssh`
- Domain #2: `ns2.example.com`, type `ssh`

Result:

- Both `ns1` and `ns2` resolve to your server.
- Each is a separate DNSTT pool but both tunnel to SSH on your server.
- Clients can pick any domain; both reach the same `vpnuser` account.

### 5.2. Example: SSH + SOCKS in one deployment

Same steps, but:

- Domain #1: `ns1.example.com`, type `ssh`
- Domain #2: `ns2.example.com`, type `socks`

Result:

- `ns1.example.com` → DNSTT → sshd → `vpnuser` (SSH tunnel).
- `ns2.example.com` → DNSTT → sing-box SOCKS5.
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
bash <(curl -sL "https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@v0.1.0/dnstun-ezpz.sh")
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

- **Per instance**:
  - Domain
  - Public key (DNSTT)
  - Type (`ssh` / `socks`)
  - SSH username/password (for `ssh` domains)
- **DNS records** (A + NS).
- **Join command** for other servers.

### 7.2. Reconfigure (2)

- Lets you change prefix, server count, SSH user/password, domains, and types.
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

