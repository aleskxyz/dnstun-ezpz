#!/usr/bin/env bash
set -e

# ===========================
# Variables
# ===========================
BASE_DIR="/opt/dnstun-ezpz"
DNSTUN_VERSION="v0.1.0"
CONFIG_FILE="$BASE_DIR/dnstun.conf"
DNS_LB_YML="$BASE_DIR/dns-lb.yml"
DOCKER_COMPOSE_YML="$BASE_DIR/docker-compose.yml"
SSHD_CONF="$BASE_DIR/dnstt.conf"
SSHD_DIR="$BASE_DIR"
HASH_FILE="$BASE_DIR/.config_hashes"
SINGBOX_CONF="$BASE_DIR/singbox.conf"
WARP_ACCOUNT_TOML="$BASE_DIR/wgcf-account.toml"
ROUTE_SETUP_SH="$BASE_DIR/route_setup.sh"

DNSTT_FIRST_PORT=48271
DNSTT_SERVER_IMAGE="aleskxyz/dnstt-server:v1.1"
DNS_LB_IMAGE="aleskxyz/dns_tunnel_lb:v0.1"
SINGBOX_SOCKS_PORT=48260
SINGBOX_IMAGE="gzxhwq/sing-box:1.12.14"
ROUTE_SETUP_IMAGE="icasture/network-helper:latest"

WGCF_IMAGE="virb3/wgcf:2.2.29"
WARP_API_ENDPOINT="https://api.cloudflareclient.com/v0a1922"
WARP_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_PEER_HOST="engage.cloudflareclient.com"
WARP_PEER_PORT="2408"

# ===========================
# Early setup (must run first)
# ===========================
check_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Error: This script must be run as root. Try: sudo $0 ${*:-}" >&2
    exit 1
  fi
}

init_basedir() {
  mkdir -p "$BASE_DIR"
}

# ===========================
# Install required packages
# ===========================
install_packages() {
  if which jq xxd >/dev/null 2>&1; then
    return 0
  fi
  if which apt >/dev/null 2>&1; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y jq xxd
    return 0
  fi
  if which yum >/dev/null 2>&1; then
    yum makecache
    yum install -y jq xxd
    return 0
  fi
  echo "Error: Could not install jq and xxd. This script requires apt (Debian/Ubuntu) or yum (RHEL/CentOS). Install them manually and rerun." >&2
  exit 1
}

# ===========================
# Install Docker and set compose command
# ===========================
install_docker() {
  if ! which docker >/dev/null 2>&1; then
    curl -fsSL -m 5 https://get.docker.com | bash
    systemctl enable --now docker
    DOCKER_CMD="docker compose"
    return 0
  fi
  if docker compose >/dev/null 2>&1; then
    DOCKER_CMD="docker compose"
    return 0
  fi
  if which docker-compose >/dev/null 2>&1; then
    DOCKER_CMD="docker-compose"
    return 0
  fi
  curl -fsSL -m 30 "https://github.com/docker/compose/releases/download/v2.28.0/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  DOCKER_CMD="docker-compose"
  return 0
}

# ===========================
# Helper functions
# ===========================
prompt_if_empty() {
  local var_name=$1
  local prompt_msg=$2
  local default_val=$3
  read -rp "$prompt_msg${default_val:+ [$default_val]}: " input
  export "$var_name"="${input:-$default_val}"
}

version_lt() {
  # returns 0 if $1 < $2 (semver-like, vMAJ.MIN.PATCH)
  local a="${1#v}"
  local b="${2#v}"
  local IFS=.
  local -a va=($a) vb=($b)
  local i
  for ((i=0;i<3;i++)); do
    local na=${va[i]:-0}
    local nb=${vb[i]:-0}
    if (( na < nb )); then
      return 0
    elif (( na > nb )); then
      return 1
    fi
  done
  return 1
}

ensure_port_53_free() {
  # Check if anything is listening on port 53 (TCP or UDP)
  local listeners
  listeners=$(ss -tulpn 2>/dev/null | awk '$5 ~ /:53$/ {print}')
  if [ -z "$listeners" ]; then
    return 0
  fi

  # If port 53 is only used by our own dns-lb container, that's fine
  if ! echo "$listeners" | grep -v "dns-tun-lb" >/dev/null 2>&1; then
    return 0
  fi

  if echo "$listeners" | grep -q "systemd-resolved"; then
    echo "Port 53 is in use by systemd-resolved. Attempting to unmanage host DNS and free port 53..."
    # Stop and disable systemd-resolved
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
    # Point host DNS directly to public resolvers with a real file
    rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' >/etc/resolv.conf
  else
    echo "Error: Port 53 is already in use by another process (not systemd-resolved):" >&2
    echo "$listeners" >&2
    echo "Free port 53 (stop or reconfigure the service using it) and rerun this script." >&2
    exit 1
  fi

  # Re-check after attempting to free
  listeners=$(ss -tulpn 2>/dev/null | awk '$5 ~ /:53$/ {print}')
  if [ -n "$listeners" ]; then
    echo "Error: Port 53 is still in use after stopping systemd-resolved:" >&2
    echo "$listeners" >&2
    echo "Free port 53 manually (e.g. stop the process above) and rerun this script." >&2
    exit 1
  fi
}

apply_config_changes() {
  declare -A old_hashes new_hashes
  local path

  # Config files we care about
  local docker_files=(
    "$DNS_LB_YML"
    "$DOCKER_COMPOSE_YML"
    "$SINGBOX_CONF"
    "$ROUTE_SETUP_SH"
  )
  local ssh_files=(
    "$SSHD_CONF"
  )

  # Load old hashes
  if [ -f "$HASH_FILE" ]; then
    while IFS='|' read -r p h; do
      [ -n "$p" ] && old_hashes["$p"]="$h"
    done <"$HASH_FILE"
  fi

  local docker_changed=0
  local sshd_changed=0

  # Check docker-related files
  for path in "${docker_files[@]}"; do
    [ -f "$path" ] || continue
    new_hashes["$path"]="$(sha256sum "$path" | awk '{print $1}')"
    if [ "${new_hashes[$path]}" != "${old_hashes[$path]:-}" ]; then
      docker_changed=1
    fi
  done

  # Check SSH config
  for path in "${ssh_files[@]}"; do
    [ -f "$path" ] || continue
    new_hashes["$path"]="$(sha256sum "$path" | awk '{print $1}')"
    if [ "${new_hashes[$path]}" != "${old_hashes[$path]:-}" ]; then
      sshd_changed=1
    fi
  done

  # Apply restarts once
  if [ "$docker_changed" -eq 1 ]; then
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" down --remove-orphans
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" up -d --remove-orphans
  fi
  if [ "$sshd_changed" -eq 1 ]; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  fi

  # Rewrite hash file with current hashes
  local tmp_hash
  tmp_hash="$(mktemp)"
  for path in "${!new_hashes[@]}"; do
    echo "$path|${new_hashes[$path]}" >>"$tmp_hash"
  done
  mv "$tmp_hash" "$HASH_FILE"
}

load_join_config() {
  local b64="$1"
  local join_json
  join_json=$(echo "$b64" | base64 -d 2>/dev/null) || { echo "Error: Invalid join config: base64 decode failed. Check the join token and try again." >&2; exit 1; }
  local join_version
  join_version=$(echo "$join_json" | jq -r '.VERSION // empty')
  if [[ -z "$join_version" ]]; then
    echo "Error: Join config is missing VERSION field; cannot verify compatibility." >&2
    echo "Re-generate the join command on the source node (dnstun-ezpz $DNSTUN_VERSION) and try again." >&2
    exit 1
  fi
  if version_lt "$DNSTUN_VERSION" "$join_version"; then
    echo "Error: Join config was generated by newer dnstun-ezpz $join_version." >&2
    echo "You are running $DNSTUN_VERSION. Upgrade this script to at least $join_version and rerun the join command." >&2
    exit 1
  elif version_lt "$join_version" "$DNSTUN_VERSION"; then
    echo "Error: Join config was generated by older dnstun-ezpz $join_version." >&2
    echo "You are running $DNSTUN_VERSION. Upgrade the source node to $DNSTUN_VERSION, re-generate the join command, then try again." >&2
    exit 1
  fi
  PREFIX=$(echo "$join_json" | jq -r '.PREFIX // empty')
  NUM_SERVERS=$(echo "$join_json" | jq -r '.NUM_SERVERS // empty')
  SSH_USER=$(echo "$join_json" | jq -r '.SSH_USER // empty')
  SSH_PASS=$(echo "$join_json" | jq -r '.SSH_PASS // empty')
  PRIVKEY=$(echo "$join_json" | jq -r '.PRIVKEY // empty')
  PUBKEY=$(echo "$join_json" | jq -r '.PUBKEY // empty')
  DOMAINS=()
  while IFS= read -r line; do [[ -n "$line" ]] && DOMAINS+=("$line"); done < <(echo "$join_json" | jq -r '.DOMAINS[]? // empty')
  DOMAIN_TYPES=()
  while IFS= read -r line; do [[ -n "$line" ]] && DOMAIN_TYPES+=("$line"); done < <(echo "$join_json" | jq -r '.DOMAIN_TYPES[]? // empty')
  if [[ -z "$PREFIX" || -z "$NUM_SERVERS" || -z "$SSH_USER" || -z "$SSH_PASS" || -z "$PRIVKEY" || -z "$PUBKEY" || ${#DOMAINS[@]} -eq 0 ]]; then
    echo "Error: Invalid join config: missing required fields (PREFIX, NUM_SERVERS, SSH_USER, SSH_PASS, PRIVKEY, PUBKEY, or DOMAINS)." >&2
    echo "Re-generate the join command on the source node and try again." >&2
    exit 1
  fi
  if [[ ${#DOMAIN_TYPES[@]} -ne ${#DOMAINS[@]} ]]; then
    echo "Error: Invalid join config: DOMAIN_TYPES count does not match DOMAINS. Re-generate the join command and try again." >&2
    exit 1
  fi
}

print_current_config() {
  local base_domain="${DOMAINS[0]#*.}"
  echo
  echo "==== CLIENT CONFIG (per instance) ===="
  for i in "${!DOMAINS[@]}"; do
    local domain=${DOMAINS[$i]}
    local domain_type=${DOMAIN_TYPES[$i]}
    echo
    echo "--- Instance $((i+1)) ---"
    echo "Domain: $domain"
    echo "Public key: $PUBKEY"
    echo "Type: $domain_type"
    if [[ "$domain_type" == "ssh" ]]; then
      echo "SSH username: $SSH_USER"
      echo "SSH password: $SSH_PASS"
    fi
    echo "-------------------"
  done
  echo
  echo "==== DNS RECORDS TO CREATE ===="
  echo
  echo "1) A records (zone: $base_domain) — point each server hostname to that server's public IP:"
  echo
  for ((j=1;j<=NUM_SERVERS;j++)); do
    echo "   ${PREFIX}${j}.$base_domain   A   <server-${j}-public-ip>"
  done
  echo
  echo "2) NS records — for each domain, delegate to the servers (in the parent zone of each domain):"
  echo
  for i in "${!DOMAINS[@]}"; do
    local domain=${DOMAINS[$i]}
    echo "   For $domain:"
    for ((j=1;j<=NUM_SERVERS;j++)); do
      echo "   $domain   NS   ${PREFIX}${j}.$base_domain."
    done
    echo
  done
  echo "==== CLUSTER CREATED ===="
  local join_json
  join_json=$(cat <<EOF
{
  "VERSION":"$DNSTUN_VERSION",
  "PREFIX":"$PREFIX",
  "NUM_SERVERS":"$NUM_SERVERS",
  "SSH_USER":"$SSH_USER",
  "SSH_PASS":"$SSH_PASS",
  "DOMAINS":$(printf '%s\n' "${DOMAINS[@]}" | jq -R -s -c 'split("\n")[:-1]'),
  "DOMAIN_TYPES":$(printf '%s\n' "${DOMAIN_TYPES[@]}" | jq -R -s -c 'split("\n")[:-1]'),
  "PRIVKEY":"$PRIVKEY",
  "PUBKEY":"$PUBKEY"
}
EOF
  )
  local join_b64
  join_b64="$(echo "$join_json" | base64 -w 0)"
  echo "Join command (run this on other servers to join the cluster):"
  echo
  echo "bash <(curl -sL \"https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@${DNSTUN_VERSION}/dnstun-ezpz.sh\") \"$join_b64\""
  echo
}

# ===========================
# WARP account (create without license, TOML + API)
# ===========================
warp_api() {
  local verb="$1" resource="$2" data="$3" token="$4"
  local temp_file response_code response_body
  local headers=("User-Agent: okhttp/3.12.1" "CF-Client-Version: a-6.3-1922" "Content-Type: application/json")
  temp_file=$(mktemp)
  [[ -n "${token}" ]] && headers+=("Authorization: Bearer ${token}")
  local cmd="curl -sLX ${verb} -m 10 -w '%{http_code}' -o ${temp_file} ${WARP_API_ENDPOINT}${resource}"
  for h in "${headers[@]}"; do cmd+=" -H '${h}'"; done
  [[ -n "${data}" ]] && cmd+=" -d '${data}'"
  response_code=$(eval "${cmd}" || echo "000")
  response_body=$(cat "${temp_file}")
  rm -f "${temp_file}"
  if [[ "${response_code}" == "000" ]] || [[ "${response_code}" -eq 0 ]]; then
    echo "WARP API request failed (curl error)" >&2
    return 1
  fi
  if [[ "${response_code}" -gt 399 ]]; then
    local err; err=$(echo "${response_body}" | jq -r '.errors[0].message' 2>/dev/null || true)
    [[ "${err}" != "null" && -n "${err}" ]] && echo "${err}" >&2
    return 2
  fi
  echo "${response_body}"
}

warp_decode_reserved() {
  local client_id="$1"
  echo "${client_id}" | base64 -d 2>/dev/null | xxd -p | fold -w2 | while read -r HEX; do printf '%d ' "0x${HEX}"; done | awk '{print "["$1", "$2", "$3"]"}'
}

warp_create_account() {
  local warp_data_dir="$1" warp_account_toml="$2"
  mkdir -p "${warp_data_dir}"
  echo "Registering WARP device (accepting ToS) via wgcf..." >&2
  if ! docker run --rm -i -v "${warp_data_dir}":/data "${WGCF_IMAGE}" register --config /data/wgcf-account.toml --accept-tos; then
    echo "WARP registration failed (wgcf could not register device). Check network and Docker, then try again." >&2
    return 1
  fi
  if [[ ! -r "${warp_account_toml}" ]]; then
    echo "WARP account file not found after registration: ${warp_account_toml}" >&2
    return 1
  fi
  return 0
}

warp_load_from_toml() {
  local warp_account_toml="$1"
  local token id pk response
  [[ ! -r "${warp_account_toml}" ]] && return 1
  token=$(grep 'access_token' "${warp_account_toml}" | cut -d "'" -f2)
  id=$(grep 'device_id' "${warp_account_toml}" | cut -d "'" -f2)
  pk=$(grep 'private_key' "${warp_account_toml}" | cut -d "'" -f2)
  [[ -z "${token}" || -z "${id}" || -z "${pk}" ]] && return 1
  response=$(warp_api "GET" "/reg/${id}" "" "${token}") || return 1
  WARP_TOKEN="${token}"
  WARP_ID="${id}"
  WARP_PRIVATE_KEY="${pk}"
  WARP_CLIENT_ID=$(echo "${response}" | jq -r '.config.client_id')
  WARP_INTERFACE_IPV4=$(echo "${response}" | jq -r '.config.interface.addresses.v4')
  WARP_INTERFACE_IPV6=$(echo "${response}" | jq -r '.config.interface.addresses.v6')
  if [[ -z "${WARP_CLIENT_ID}" || "${WARP_CLIENT_ID}" == "null" ]] || \
     [[ -z "${WARP_INTERFACE_IPV4}" || "${WARP_INTERFACE_IPV4}" == "null" ]] || \
     [[ -z "${WARP_INTERFACE_IPV6}" || "${WARP_INTERFACE_IPV6}" == "null" ]]; then
    return 1
  fi
  return 0
}

warp_delete_account() {
  local warp_account_toml="$1"
  local token id
  if ! warp_load_from_toml "$warp_account_toml"; then
    return 0
  fi
  token="$WARP_TOKEN"
  id="$WARP_ID"
  if [[ -z "$id" || -z "$token" ]]; then
    return 0
  fi
  warp_api "DELETE" "/reg/${id}" "" "$token" >/dev/null 2>&1 || true
  rm -f "$warp_account_toml"
  echo "Deleted WARP account and removed $warp_account_toml" >&2
  return 0
}

# ===========================
# Load config: join argument or existing file
# ===========================
load_initial_config() {
  DOMAINS=()
  DOMAIN_TYPES=()
  JOIN_MODE=0
  if [[ -n "${1:-}" ]]; then
    echo "==== JOIN CLUSTER (from join config) ===="
    load_join_config "$1"
    JOIN_MODE=1
    ACTION=2
  elif [ -f "$CONFIG_FILE" ]; then
    CONFIG_VERSION_STORED=$(awk -F'=' '/^CONFIG_VERSION=/{gsub(/"/,"",$2); print $2}' "$CONFIG_FILE" | tail -n1 || true)
    if [[ -n "$CONFIG_VERSION_STORED" ]]; then
      if version_lt "$DNSTUN_VERSION" "$CONFIG_VERSION_STORED"; then
        echo "Error: Local config was created with newer dnstun-ezpz $CONFIG_VERSION_STORED." >&2
        echo "You are running $DNSTUN_VERSION. Upgrade this script to at least $CONFIG_VERSION_STORED and rerun." >&2
        exit 1
      elif [[ "$CONFIG_VERSION_STORED" != "$DNSTUN_VERSION" ]]; then
        echo "WARNING: This node was previously configured with dnstun-ezpz $CONFIG_VERSION_STORED." >&2
        echo "You are now running script version $DNSTUN_VERSION." >&2
        echo "If you continue and reconfigure this node, it will be upgraded." >&2
        echo "After upgrading, you must re-run the new join command on all other nodes" >&2
        echo "so that the entire cluster runs the same version." >&2
        echo >&2
      fi
    fi
    source "$CONFIG_FILE"
    CONFIG_EXISTS=1
  else
    CONFIG_EXISTS=0
  fi
}

# ===========================
# Interactive menu and reconfigure prompts
# ===========================
run_menu_or_reconfigure() {
  if [[ $JOIN_MODE -ne 0 ]]; then
    return 0
  fi
  if [ "${CONFIG_EXISTS:-0}" -eq 1 ]; then
    echo "Select action:"
    echo "1) Print current config"
    echo "2) Reconfigure cluster"
    echo "3) Start services"
    echo "4) Stop services"
    echo "5) Restart services"
    echo "6) Uninstall cluster"
    read -rp "Enter choice [1-6]: " ACTION
    ACTION="${ACTION:-1}"
  else
    ACTION=2
  fi

  if [ "$ACTION" == "1" ]; then
    print_current_config
    exit 0
  fi

  if [ "$ACTION" == "3" ]; then
    echo "Starting services with existing docker-compose.yml..."
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" up -d --remove-orphans
    exit 0
  fi

  if [ "$ACTION" == "4" ]; then
    echo "Stopping services..."
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" stop
    exit 0
  fi

  if [ "$ACTION" == "5" ]; then
    echo "Restarting services..."
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" down --remove-orphans
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" up -d --remove-orphans
    exit 0
  fi

  if [ "$ACTION" == "6" ]; then
    echo "Uninstalling cluster (stopping and removing containers, keeping this script)..."
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" down --remove-orphans || true
    if [ -f "$WARP_ACCOUNT_TOML" ]; then
      warp_delete_account "$WARP_ACCOUNT_TOML"
    fi
    if id "$SSH_USER" >/dev/null 2>&1; then
      userdel "$SSH_USER" || echo "Warning: failed to delete SSH user $SSH_USER" >&2
    fi
    rm -rf "$BASE_DIR"
    echo "Cluster directory $BASE_DIR has been removed."
    exit 0
  fi

  # RECONFIGURE CLUSTER (prompts)
  echo "==== CREATE CLUSTER ===="
  prompt_if_empty PREFIX "Enter prefix for server domain names" "${PREFIX:-s}"
  while true; do
    prompt_if_empty NUM_SERVERS "Enter number of servers" "${NUM_SERVERS:-3}"
    if [[ "$NUM_SERVERS" =~ ^[0-9]+$ ]] && [[ "$NUM_SERVERS" -ge 1 ]]; then
      break
    fi
    echo "Must be a positive number." >&2
  done
  prompt_if_empty SSH_USER "Enter SSH username" "${SSH_USER:-vpnuser}"
  prompt_if_empty SSH_PASS "Enter SSH password" "$SSH_PASS"

  DEFAULT_NUM_DOMAINS=${#DOMAINS[@]}
  if [ "$DEFAULT_NUM_DOMAINS" -eq 0 ]; then
    DEFAULT_NUM_DOMAINS=1
  fi
  while true; do
    read -rp "Enter number of domains [${DEFAULT_NUM_DOMAINS:-1}]: " NUM_DOMAINS_INPUT
    NUM_DOMAINS=${NUM_DOMAINS_INPUT:-$DEFAULT_NUM_DOMAINS}
    if [[ "$NUM_DOMAINS" =~ ^[0-9]+$ ]] && [[ "$NUM_DOMAINS" -ge 1 ]]; then
      break
    fi
    echo "At least one domain is required. Must be a positive number." >&2
  done
  NEW_DOMAINS=()
  NEW_DOMAIN_TYPES=()

  for ((i=0;i<NUM_DOMAINS;i++)); do
    DEFAULT_NAME="${DOMAINS[$i]}"
    prompt_if_empty DOMAIN_NAME "Enter domain name #$((i+1))" "$DEFAULT_NAME"
    NEW_DOMAINS+=("$DOMAIN_NAME")

    DEFAULT_TYPE="${DOMAIN_TYPES[$i]}"
    while true; do
      read -rp "Enter type for $DOMAIN_NAME (ssh/socks)${DEFAULT_TYPE:+ [$DEFAULT_TYPE]}: " TYPE
      TYPE="${TYPE:-$DEFAULT_TYPE}"
      TYPE=${TYPE,,}
      if [[ "$TYPE" == "ssh" || "$TYPE" == "socks" ]]; then
        NEW_DOMAIN_TYPES+=("$TYPE")
        break
      else
        echo "Invalid type. Must be 'ssh' or 'socks'."
      fi
    done
  done

  DOMAINS=("${NEW_DOMAINS[@]}")
  DOMAIN_TYPES=("${NEW_DOMAIN_TYPES[@]}")

  if [ -z "$PRIVKEY" ]; then
    echo "Generating DNSTT key..."
    KEYS=$(docker run --rm $DNSTT_SERVER_IMAGE -gen-key)
    PRIVKEY=$(echo "$KEYS" | grep 'privkey' | awk '{print $2}')
    PUBKEY=$(echo "$KEYS" | grep 'pubkey' | awk '{print $2}')
  fi
}

# ===========================
# Save config to file
# ===========================
save_config() {
  {
    echo "CONFIG_VERSION=\"$DNSTUN_VERSION\""
    echo "PREFIX=\"$PREFIX\""
    echo "NUM_SERVERS=\"$NUM_SERVERS\""
    echo "SSH_USER=\"$SSH_USER\""
    echo "SSH_PASS=\"$SSH_PASS\""
    echo "PRIVKEY=\"$PRIVKEY\""
    echo "PUBKEY=\"$PUBKEY\""
    printf "DOMAINS=("
    for d in "${DOMAINS[@]}"; do printf "\"%s\" " "$d"; done
    echo ")"
    printf "DOMAIN_TYPES=("
    for t in "${DOMAIN_TYPES[@]}"; do printf "\"%s\" " "$t"; done
    echo ")"
  } > "$CONFIG_FILE"
}

# ===========================
# Detect SSH port
# ===========================
detect_ssh_port() {
  SSHD_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | sed 's/.*://g' | sort -n | tail -n1)
  if [[ -z "$SSHD_PORT" || ! "$SSHD_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not detect SSH port (sshd not listening?). Start sshd or ensure it is listening, then rerun this script." >&2
    exit 1
  fi
  echo "Detected SSH port: $SSHD_PORT"
}

# ===========================
# Generate dns-lb.yml
# ===========================
# base_domain: strip first label (e.g. tunnel.example.com -> example.com). Use FQDN subdomains.
generate_dns_lb_yml() {
  BASE_DOMAIN="${DOMAINS[0]#*.}"
  PORT_COUNTER=$DNSTT_FIRST_PORT
  cat <<EOF > "$DNS_LB_YML"
# Generated by dnstun-ezpz $DNSTUN_VERSION
logging:
  level: "info"

global:
  listen_address: "0.0.0.0:53"
  default_dns_behavior:
    mode: "forward"
    forward_resolver: "127.0.0.1:$DNSTT_FIRST_PORT"

protocols:
  dnstt:
    pools:
EOF
  for i in "${!DOMAINS[@]}"; do
    DOMAIN=${DOMAINS[$i]}
    CURRENT_PORT=$PORT_COUNTER
    cat <<EOF >> "$DNS_LB_YML"
      - name: "$DOMAIN"
        domain_suffix: "$DOMAIN"
        backends:
EOF
    for ((j=1;j<=NUM_SERVERS;j++)); do
      echo "          - id: \"${PREFIX}${j}\"" >> "$DNS_LB_YML"
      echo "            address: \"${PREFIX}${j}.$BASE_DOMAIN:$CURRENT_PORT\"" >> "$DNS_LB_YML"
    done
    PORT_COUNTER=$((PORT_COUNTER+1))
  done
}
# ===========================
# Generate docker-compose.yml
# ===========================
generate_docker_compose_yml() {
  cat <<EOF > "$DOCKER_COMPOSE_YML"
# Generated by dnstun-ezpz $DNSTUN_VERSION
services:
  dns-lb:
    image: $DNS_LB_IMAGE
    restart: always
    network_mode: "host"
    command: >
      -config /etc/dns-lb.yml
    volumes:
      - $DNS_LB_YML:/etc/dns-lb.yml
    cap_add:
      - NET_BIND_SERVICE
EOF

  # Add DNSTT services
  PORT_COUNTER=$DNSTT_FIRST_PORT
  for i in "${!DOMAINS[@]}"; do
    DOMAIN=${DOMAINS[$i]}
    TYPE=${DOMAIN_TYPES[$i]}
    LOCAL_PORT=$PORT_COUNTER
    CONTAINER_NAME="dnstt-$((i+1))"
    BACKEND="$DOMAIN 127.0.0.1:$([ "$TYPE" == "ssh" ] && echo $SSHD_PORT || echo $SINGBOX_SOCKS_PORT)"
    cat <<EOF >> "$DOCKER_COMPOSE_YML"

  $CONTAINER_NAME:
    image: $DNSTT_SERVER_IMAGE
    command: >
      -mtu 512
      -privkey "$PRIVKEY"
      -udp :$LOCAL_PORT
      $BACKEND
    restart: always
    network_mode: "host"
EOF
    PORT_COUNTER=$((PORT_COUNTER+1))
  done

  # Add singbox service
  cat <<EOF >> "$DOCKER_COMPOSE_YML"

  singbox:
    image: $SINGBOX_IMAGE
    restart: always
    network_mode: "host"
    environment:
      TZ: Etc/UTC
    volumes:
      - $SINGBOX_CONF:/etc/sing-box/config.json
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
EOF

  # Add route-setup service
  cat <<EOF >> "$DOCKER_COMPOSE_YML"

  route-setup:
    image: $ROUTE_SETUP_IMAGE
    network_mode: host
    cap_add:
      - NET_ADMIN
    depends_on:
      - singbox
    environment:
      SSH_USER_ID: "$SSH_UID"
    volumes:
      - $ROUTE_SETUP_SH:/usr/local/bin/route_setup.sh:ro
    entrypoint: ["/usr/local/bin/route_setup.sh"]
    restart: always
EOF
}


# ===========================
# Generate singbox.conf from WARP TOML/API values
# ===========================
generate_singbox_conf() {
  SINGBOX_BASE=$(cat <<'SINGBOX_BASE'
{
  "log": {"level": "error", "timestamp": true},
  "dns": {
    "servers": [{"type": "tcp", "server": "1.1.1.1"}],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {"type": "socks", "listen": "127.0.0.1", "listen_port": 0}
  ],
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp",
      "system": true,
      "name": "wg0",
      "mtu": 1280,
      "address": ["0.0.0.0/32", "::/128"],
      "private_key": "",
      "listen_port": 0,
      "peers": [
        {
          "address": "",
          "port": 0,
          "public_key": "",
          "allowed_ips": ["0.0.0.0/0"],
          "persistent_keepalive_interval": 30,
          "reserved": []
        }
      ]
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "internet"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "final": "warp",
    "rule_set": [
      {"tag": "block", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/aleskxyz/sing-box-rules/refs/heads/rule-set/block.srs", "download_detour": "internet"},
      {"tag": "geoip-private", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/aleskxyz/sing-box-rules/refs/heads/rule-set/geoip-private.srs", "download_detour": "internet"},
      {"tag": "geosite-private", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/aleskxyz/sing-box-rules/refs/heads/rule-set/geosite-private.srs", "download_detour": "internet"}
    ],
    "rules": [
      {"inbound": "in", "action": "resolve", "strategy": "prefer_ipv4"},
      {"inbound": "in", "action": "sniff", "timeout": "300ms"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"port": 53, "action": "hijack-dns"},
      {"rule_set": ["block", "geoip-private", "geosite-private"], "action": "reject"},
      {"network": "tcp", "port": [25, 587, 465, 2525], "action": "reject"}
    ]
  },
  "experimental": {"cache_file": {"enabled": true}}
}
SINGBOX_BASE
  )

  # Ensure WARP account (create TOML if missing, no license)
  if ! warp_load_from_toml "$WARP_ACCOUNT_TOML"; then
    warp_create_account "$BASE_DIR" "$WARP_ACCOUNT_TOML" || { echo "Error: WARP registration failed. See message above." >&2; exit 1; }
    warp_load_from_toml "$WARP_ACCOUNT_TOML" || { echo "Error: Failed to load WARP config after registration. Check $WARP_ACCOUNT_TOML or try again." >&2; exit 1; }
  fi
  WARP_RESERVED_JSON=$(warp_decode_reserved "$WARP_CLIENT_ID")

  echo "$SINGBOX_BASE" | jq \
    --arg pk "$WARP_PRIVATE_KEY" \
    --arg v4 "$WARP_INTERFACE_IPV4" \
    --arg v6 "$WARP_INTERFACE_IPV6" \
    --arg host "$WARP_PEER_HOST" \
    --arg pub "$WARP_PEER_PUBLIC_KEY" \
    --argjson port "$WARP_PEER_PORT" \
    --argjson res "$WARP_RESERVED_JSON" \
    --argjson listen_port "$SINGBOX_SOCKS_PORT" \
    '.inbounds[0].listen_port = $listen_port |
     .endpoints[0].address = [$v4 + "/32", $v6 + "/128"] |
     .endpoints[0].private_key = $pk |
     .endpoints[0].peers[0].address = $host |
     .endpoints[0].peers[0].port = $port |
     .endpoints[0].peers[0].public_key = $pub |
     .endpoints[0].peers[0].reserved = $res' > "$SINGBOX_CONF"
}


# ===========================
# Generate route_setup.sh
# ===========================
generate_route_setup_sh() {
  cat <<'ROUTEEOF' > "$ROUTE_SETUP_SH"
#!/usr/bin/env bash
set -e

cleanup() {
  ip rule del uidrange ${SSH_USER_ID}-${SSH_USER_ID} table 200 2>/dev/null || true
  ip route del default dev wg0 table 200 2>/dev/null || true
}
trap cleanup EXIT TERM INT

while ! ip link show wg0 >/dev/null 2>&1; do
  sleep 1
done

if ! ip route show table 200 2>/dev/null | grep -q "^default .* dev wg0"; then
  ip route add default dev wg0 table 200
fi

if ! ip rule show | grep -q "uidrange ${SSH_USER_ID}-${SSH_USER_ID} .* table 200"; then
  ip rule add uidrange ${SSH_USER_ID}-${SSH_USER_ID} table 200
fi

while true; do
  sleep 3600 &
  wait $!
done
ROUTEEOF
  chmod +x "$ROUTE_SETUP_SH"
}

# ===========================
# Create SSH user for tunnel (sets SSH_UID)
# ===========================
create_ssh_user() {
  if ! id -u "$SSH_USER" &>/dev/null; then
    useradd -d /var/empty -s /usr/sbin/nologin -M -p "$(openssl passwd -6 "$SSH_PASS")" "$SSH_USER"
  fi
  SSH_UID=$(id -u "$SSH_USER" 2>/dev/null)
}

# ===========================
# SSH user match config
# ===========================
# Writes $SSHD_CONF. Ensure main sshd_config includes it, e.g.: Include $SSHD_CONF
generate_ssh_config() {
  mkdir -p "$SSHD_DIR"
  cat <<EOF > "$SSHD_CONF"
Match User $SSH_USER Address 127.0.0.1
    PasswordAuthentication yes
    AllowTcpForwarding local
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    GatewayPorts no
    ForceCommand echo 'TCP forwarding only'
EOF
}

# ===========================
# Run all config generators (order matters)
# ===========================
run_all_generators() {
  create_ssh_user
  generate_dns_lb_yml
  generate_singbox_conf
  generate_route_setup_sh
  generate_docker_compose_yml
  generate_ssh_config
}

# ===========================
# Main entry point
# ===========================
main() {
  check_root
  init_basedir
  install_packages
  install_docker
  ensure_port_53_free
  load_initial_config "$1"
  run_menu_or_reconfigure
  save_config
  detect_ssh_port
  run_all_generators
  apply_config_changes
  print_current_config
}

main "$@"