#!/usr/bin/env bash
set -e

# ===========================
# Variables
# ===========================
BASE_DIR="/opt/dnstun-ezpz"
DNSTUN_VERSION="v0.3.1"
CONFIG_FILE="$BASE_DIR/dnstun.conf"
DNS_LB_YML="$BASE_DIR/dns-lb.yml"
DOCKER_COMPOSE_YML="$BASE_DIR/docker-compose.yml"
SSHD_DIR="/etc/ssh/sshd_config.d"
SSHD_CONF="$SSHD_DIR/99-dnstun-ezpz.conf"
HASH_FILE="$BASE_DIR/.config_hashes"
SINGBOX_CONF="$BASE_DIR/singbox.conf"
WARP_ACCOUNT_TOML="$BASE_DIR/wgcf-account.toml"
ROUTE_SETUP_SH="$BASE_DIR/route_setup.sh"

TRANSPORT_FIRST_PORT=48271
DNSTT_SERVER_IMAGE="ghcr.io/aleskxyz/dnstt-server:1.1.0"
SLIPSTREAM_SERVER_IMAGE="aleskxyz/slipstream-server:1.1.3"
DNS_LB_IMAGE="ghcr.io/aleskxyz/dns-tun-lb:0.2.6"
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
  if which jq xxd qrencode >/dev/null 2>&1; then
    return 0
  fi
  if which apt >/dev/null 2>&1; then
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y jq xxd qrencode
    return 0
  fi
  if which yum >/dev/null 2>&1; then
    yum makecache
    yum install -y jq xxd qrencode
    return 0
  fi
  echo "Error: Could not install jq, xxd, and qrencode. This script requires apt (Debian/Ubuntu) or yum (RHEL/CentOS). Install them manually and rerun." >&2
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

# Derive X25519 public key (hex) from private key (hex). Sets PUBKEY; no-op if PRIVKEY empty.
derive_pubkey() {
  [[ -z "$PRIVKEY" ]] && return 0
  PUBKEY=$( ( printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'; echo -n "$PRIVKEY" | xxd -r -p ) | openssl pkey -in /dev/stdin -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 0 )
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

# Join payload keys (2-letter, compact): ve=version, pr=prefix, ns=num_servers, au=auth_user, ap=auth_pass, dm=domains, pc=protocols, ts=transports, pk=privkey (pubkey derived from it)
load_join_config() {
  local b64="$1"
  local join_json
  join_json=$(echo "$b64" | base64 -d 2>/dev/null) || { echo "Error: Invalid join config: base64 decode failed. Check the join token and try again." >&2; exit 1; }
  local join_version
  join_version=$(echo "$join_json" | jq -r '.ve // empty')
  if [[ -z "$join_version" ]]; then
    echo "Error: Join config is missing version field; cannot verify compatibility." >&2
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
  PREFIX=$(echo "$join_json" | jq -r '.pr // empty')
  NUM_SERVERS=$(echo "$join_json" | jq -r '.ns // empty')
  AUTH_USER=$(echo "$join_json" | jq -r '.au // empty')
  AUTH_PASS=$(echo "$join_json" | jq -r '.ap // empty')
  PRIVKEY=$(echo "$join_json" | jq -r '.pk // empty')
  DOMAINS=()
  while IFS= read -r line; do [[ -n "$line" ]] && DOMAINS+=("$line"); done < <(echo "$join_json" | jq -r '.dm[]? // empty')
  PROTOCOLS=()
  while IFS= read -r line; do [[ -n "$line" ]] && PROTOCOLS+=("$line"); done < <(echo "$join_json" | jq -r '.pc[]? // empty')
  TRANSPORTS=()
  while IFS= read -r line; do [[ -n "$line" ]] && TRANSPORTS+=("$line"); done < <(echo "$join_json" | jq -r '.ts[]? // empty')
  if [[ -z "$PREFIX" || -z "$NUM_SERVERS" || -z "$AUTH_USER" || -z "$AUTH_PASS" || ${#DOMAINS[@]} -eq 0 ]]; then
    echo "Error: Invalid join config: missing required fields (PREFIX, NUM_SERVERS, AUTH_USER, AUTH_PASS, or DOMAINS)." >&2
    echo "Re-generate the join command on the source node and try again." >&2
    exit 1
  fi
  local need_key=0
  for t in "${TRANSPORTS[@]}"; do [[ "$t" == "dnstt" ]] && need_key=1; done
  if [[ $need_key -eq 1 && -z "$PRIVKEY" ]]; then
    echo "Error: Invalid join config: pk (privkey) required when any domain uses dnstt transport." >&2
    exit 1
  fi
  derive_pubkey
  if [[ ${#PROTOCOLS[@]} -ne ${#DOMAINS[@]} ]]; then
    echo "Error: Invalid join config: protocol count does not match domains. Re-generate the join command and try again." >&2
    exit 1
  fi
  if [[ ${#TRANSPORTS[@]} -ne ${#DOMAINS[@]} ]]; then
    echo "Error: Invalid join config: transport count does not match domains. Re-generate the join command and try again." >&2
    exit 1
  fi
}

generate_slipnet_uri() {
  local transport="$1" protocol="$2" domain="$3" pubkey="$4"
  local auth_user="$5" auth_pass="$6" profile_name="$7"

  local tunnel_type
  case "${transport}_${protocol}" in
    dnstt_ssh)        tunnel_type="dnstt_ssh" ;;
    dnstt_socks)      tunnel_type="dnstt" ;;
    slipstream_ssh)   tunnel_type="slipstream_ssh" ;;
    slipstream_socks) tunnel_type="ss" ;;
  esac

  local ssh_enabled="0" ssh_user="" ssh_pass=""
  if [[ "$protocol" == "ssh" ]]; then
    ssh_enabled="1"
    ssh_user="$auth_user"
    ssh_pass="$auth_pass"
  fi

  # v17 pipe-delimited format (38 fields, positions 0-37)
  local fields="17|${tunnel_type}|${profile_name}|${domain}"
  fields+="|8.8.8.8:53:0|0|5000|bbr|1080|127.0.0.1|0"
  fields+="|${pubkey}|${auth_user}|${auth_pass}"
  fields+="|${ssh_enabled}|${ssh_user}|${ssh_pass}|22|0|127.0.0.1"
  fields+="|0||udp|password||||0|443|||0||0|0||0|"

  printf '%s' "slipnet://$(printf '%s' "$fields" | base64 -w 0)"
}

print_current_config() {
  local base_domain="${DOMAINS[0]#*.}"
  echo
  echo "Server ID: $SERVER_ID"
  echo
  echo "==== CLIENT CONFIG ===="
  for i in "${!DOMAINS[@]}"; do
    local domain=${DOMAINS[$i]}
    local protocol=${PROTOCOLS[$i]}
    local transport=${TRANSPORTS[$i]}
    echo
    echo "--- Instance $((i+1)) ---"
    echo "domain: $domain"
    echo "transport: $transport"
    echo "protocol: $protocol"
    echo "username: $AUTH_USER"
    echo "password: $AUTH_PASS"
    if [[ "$transport" == "dnstt" ]]; then
      echo "public_key: $PUBKEY"
    fi
    local slipnet_uri
    slipnet_uri=$(generate_slipnet_uri "$transport" "$protocol" "$domain" "${PUBKEY:-}" "$AUTH_USER" "$AUTH_PASS" "${transport}-${protocol} (${domain})")
    echo
    echo "SlipNet URI:"
    echo "$slipnet_uri"
    echo
    qrencode -t UTF8 <<< "$slipnet_uri"
    echo "---"
  done
  echo
  echo "==== DNS RECORDS TO CREATE ===="
  echo
  echo "1) A records (zone: $base_domain) — point each server hostname to that server's public IP (server id in brackets):"
  echo
  for ((j=1;j<=NUM_SERVERS;j++)); do
    echo "   ${PREFIX}${j}.$base_domain   A   <server-${j}-public-ip>   [server id: $j]"
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
  echo "==== JOIN COMMAND (run on other servers to join this cluster) ===="
  local join_json
  join_json=$(jq -n -c \
    --arg ve "$DNSTUN_VERSION" \
    --arg pr "$PREFIX" \
    --argjson ns "$NUM_SERVERS" \
    --arg au "$AUTH_USER" \
    --arg ap "$AUTH_PASS" \
    --arg pk "$PRIVKEY" \
    --argjson dm "$(printf '%s\n' "${DOMAINS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson pc "$(printf '%s\n' "${PROTOCOLS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    --argjson ts "$(printf '%s\n' "${TRANSPORTS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
    '{ve: $ve, pr: $pr, ns: $ns, au: $au, ap: $ap, dm: $dm, pc: $pc, ts: $ts, pk: $pk}')
  local join_b64
  join_b64="$(echo -n "$join_json" | base64 -w 0)"
  echo "Run on other servers to join:"
  echo
  echo "  bash <(curl -sL \"https://cdn.jsdelivr.net/gh/aleskxyz/dnstun-ezpz@${DNSTUN_VERSION}/dnstun-ezpz.sh\") \"$join_b64\""
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
  PROTOCOLS=()
  TRANSPORTS=()
  JOIN_MODE=0
  if [[ -n "${1:-}" ]]; then
    echo "==== JOIN CLUSTER (from join config) ===="
    load_join_config "$1"
    if [[ -f "$CONFIG_FILE" ]]; then
      existing_server_id=$(awk -F'=' '/^SERVER_ID=/{gsub(/"/,"",$2); print $2}' "$CONFIG_FILE" | tail -n1)
      if [[ -n "$existing_server_id" ]] && [[ "$existing_server_id" =~ ^[0-9]+$ ]] && [[ "$existing_server_id" -ge 1 ]] && [[ "$existing_server_id" -le 255 ]]; then
        SERVER_ID="$existing_server_id"
      fi
    fi
    while true; do
      read -rp "Enter this server's ID (1-255)${SERVER_ID:+ [$SERVER_ID]}: " SERVER_ID_INPUT
      candidate="${SERVER_ID_INPUT:-$SERVER_ID}"
      if [[ "$candidate" =~ ^[0-9]+$ ]] && [[ "$candidate" -ge 1 ]] && [[ "$candidate" -le 255 ]]; then
        SERVER_ID="$candidate"
        break
      fi
      echo "Invalid. Server ID must be between 1 and 255." >&2
    done
    JOIN_MODE=1
    ACTION=2
  elif [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [[ -n "${CONFIG_VERSION:-}" ]]; then
      if version_lt "$DNSTUN_VERSION" "$CONFIG_VERSION"; then
        echo "Error: Local config was created with newer dnstun-ezpz $CONFIG_VERSION." >&2
        echo "You are running $DNSTUN_VERSION. Upgrade this script to at least $CONFIG_VERSION and rerun." >&2
        exit 1
      elif [[ "$CONFIG_VERSION" != "$DNSTUN_VERSION" ]]; then
        echo "WARNING: This node was previously configured with dnstun-ezpz $CONFIG_VERSION." >&2
        echo "You are now running script version $DNSTUN_VERSION." >&2
        echo "If you continue and reconfigure this node, it will be upgraded." >&2
        echo "After upgrading, you must re-run the new join command on all other nodes" >&2
        echo "so that the entire cluster runs the same version." >&2
        echo >&2
      fi
    fi
    if [[ ! "${SERVER_ID:-}" =~ ^[0-9]+$ ]] || [[ "$SERVER_ID" -lt 1 ]] || [[ "$SERVER_ID" -gt 255 ]]; then
      echo "Error: SERVER_ID is missing or invalid (must be 1-255). Reconfigure the cluster (option 2) to set this server's ID." >&2
      exit 1
    fi
    derive_pubkey
    if [[ ${#PROTOCOLS[@]} -ne ${#DOMAINS[@]} || ${#TRANSPORTS[@]} -ne ${#DOMAINS[@]} ]]; then
      echo "Error: Config is missing or has invalid PROTOCOLS/TRANSPORTS (length must match DOMAINS). Reconfigure the cluster (option 2)." >&2
      exit 1
    fi
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
    while true; do
      read -rp "Enter choice [1-6]: " ACTION
      ACTION="${ACTION:-1}"
      if [[ "$ACTION" =~ ^[1-6]$ ]]; then
        break
      fi
      echo "Invalid choice. Enter a number from 1 to 6." >&2
    done
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
    echo "Uninstalling cluster (stopping and removing containers and volumes, keeping this script)..."
    $DOCKER_CMD -f "$DOCKER_COMPOSE_YML" down -v --remove-orphans || true
    if [ -f "$WARP_ACCOUNT_TOML" ]; then
      warp_delete_account "$WARP_ACCOUNT_TOML"
    fi
    if id "$AUTH_USER" >/dev/null 2>&1; then
      userdel "$AUTH_USER" || echo "Warning: failed to delete tunnel user $AUTH_USER" >&2
    fi
    rm -f "$SSHD_CONF"
    rm -rf "$BASE_DIR"
    echo "Cluster directory $BASE_DIR has been removed."
    exit 0
  fi

  # RECONFIGURE CLUSTER (prompts)
  echo "==== CREATE CLUSTER ===="
  OLD_AUTH_USER="${AUTH_USER:-}"
  while true; do
    read -rp "Enter this server's ID (1-255)${SERVER_ID:+ [$SERVER_ID]}: " SERVER_ID_INPUT
    candidate="${SERVER_ID_INPUT:-$SERVER_ID}"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && [[ "$candidate" -ge 1 ]] && [[ "$candidate" -le 255 ]]; then
      SERVER_ID="$candidate"
      break
    fi
    echo "Invalid. Server ID must be between 1 and 255." >&2
  done
  while true; do
    PREFIX_SAVED="$PREFIX"
    prompt_if_empty PREFIX "Enter prefix for server domain names" "${PREFIX:-s}"
    # DNS label: 1-63 chars, alphanumeric and hyphen, no leading/trailing hyphen
    if [[ "${#PREFIX}" -ge 1 ]] && [[ "${#PREFIX}" -le 63 ]] && [[ "$PREFIX" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
      break
    fi
    PREFIX="${PREFIX_SAVED:-s}"
    echo "Invalid prefix. Use 1-63 characters: letters, digits, hyphens (not at start or end)." >&2
  done
  while true; do
    NUM_SERVERS_SAVED="$NUM_SERVERS"
    prompt_if_empty NUM_SERVERS "Enter number of servers" "${NUM_SERVERS:-3}"
    if [[ "$NUM_SERVERS" =~ ^[0-9]+$ ]] && [[ "$NUM_SERVERS" -ge 1 ]] && [[ "$NUM_SERVERS" -le 255 ]]; then
      break
    fi
    NUM_SERVERS="${NUM_SERVERS_SAVED:-3}"
    echo "Invalid. Must be a number between 1 and 255." >&2
  done
  while true; do
    AUTH_USER_SAVED="$AUTH_USER"
    prompt_if_empty AUTH_USER "Enter username (for SSH and SOCKS)" "${AUTH_USER:-vpnuser}"
    # Linux username: start with letter or underscore, then letters digits underscore hyphen, 1-32 chars
    if [[ "${#AUTH_USER}" -ge 1 ]] && [[ "${#AUTH_USER}" -le 32 ]] && [[ "$AUTH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      break
    fi
    AUTH_USER="${AUTH_USER_SAVED:-vpnuser}"
    echo "Invalid username. Use 1-32 chars: start with letter or underscore, then letters, digits, underscore, hyphen." >&2
  done
  while true; do
    AUTH_PASS_SAVED="$AUTH_PASS"
    prompt_if_empty AUTH_PASS "Enter password (for SSH and SOCKS)" "$AUTH_PASS"
    if [[ -n "$AUTH_PASS" ]]; then
      if [[ "$AUTH_PASS" == *'"'* || "$AUTH_PASS" == *'\'* ]]; then
        echo "Password must not contain double-quote or backslash." >&2
        AUTH_PASS="$AUTH_PASS_SAVED"
      else
        break
      fi
    else
      echo "Password cannot be empty." >&2
      AUTH_PASS="$AUTH_PASS_SAVED"
    fi
  done

  DEFAULT_NUM_DOMAINS=${#DOMAINS[@]}
  if [ "$DEFAULT_NUM_DOMAINS" -eq 0 ]; then
    DEFAULT_NUM_DOMAINS=1
  fi
  while true; do
    read -rp "Enter number of domains [${DEFAULT_NUM_DOMAINS:-1}]: " NUM_DOMAINS_INPUT
    candidate="${NUM_DOMAINS_INPUT:-$DEFAULT_NUM_DOMAINS}"
    if [[ "$candidate" =~ ^[0-9]+$ ]] && [[ "$candidate" -ge 1 ]] && [[ "$candidate" -le 100 ]]; then
      NUM_DOMAINS="$candidate"
      break
    fi
    echo "Invalid. Must be a number between 1 and 100." >&2
  done
  NEW_DOMAINS=()
  NEW_PROTOCOLS=()
  NEW_TRANSPORTS=()

  for ((i=0;i<NUM_DOMAINS;i++)); do
    DEFAULT_NAME="${DOMAINS[$i]}"
    while true; do
      prompt_if_empty DOMAIN_NAME "Enter domain name #$((i+1))" "$DEFAULT_NAME"
      # FQDN: 1-253 chars, labels of letters/digits/hyphen, separated by dots, no leading/trailing dot, no ..
      if [[ "${#DOMAIN_NAME}" -ge 1 ]] && [[ "${#DOMAIN_NAME}" -le 253 ]] && \
         [[ "$DOMAIN_NAME" != .* ]] && [[ "$DOMAIN_NAME" != *. ]] && [[ "$DOMAIN_NAME" != *..* ]] && \
         [[ "$DOMAIN_NAME" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        break
      fi
      DOMAIN_NAME="$DEFAULT_NAME"
      echo "Invalid domain. Use a valid hostname: 1-253 chars, letters/digits/hyphens, labels separated by dots (e.g. ns1.example.com)." >&2
    done
    NEW_DOMAINS+=("$DOMAIN_NAME")

    DEFAULT_TRANSPORT="${TRANSPORTS[$i]}"
    while true; do
      read -rp "Enter transport for $DOMAIN_NAME (dnstt/slipstream)${DEFAULT_TRANSPORT:+ [$DEFAULT_TRANSPORT]}: " TR
      candidate="${TR:-$DEFAULT_TRANSPORT}"
      candidate=${candidate,,}
      if [[ "$candidate" == "dnstt" || "$candidate" == "slipstream" ]]; then
        NEW_TRANSPORTS+=("$candidate")
        break
      else
        echo "Invalid transport. Must be 'dnstt' or 'slipstream'." >&2
      fi
    done

    DEFAULT_PROTOCOL="${PROTOCOLS[$i]}"
    while true; do
      read -rp "Enter protocol for $DOMAIN_NAME (ssh/socks)${DEFAULT_PROTOCOL:+ [$DEFAULT_PROTOCOL]}: " PROTOCOL
      candidate="${PROTOCOL:-$DEFAULT_PROTOCOL}"
      candidate=${candidate,,}
      if [[ "$candidate" == "ssh" || "$candidate" == "socks" ]]; then
        NEW_PROTOCOLS+=("$candidate")
        break
      else
        echo "Invalid protocol. Must be 'ssh' or 'socks'." >&2
      fi
    done
  done

  DOMAINS=("${NEW_DOMAINS[@]}")
  PROTOCOLS=("${NEW_PROTOCOLS[@]}")
  TRANSPORTS=("${NEW_TRANSPORTS[@]}")

  local need_dnstt_key=0
  for t in "${TRANSPORTS[@]}"; do [[ "$t" == "dnstt" ]] && need_dnstt_key=1; done
  if [[ $need_dnstt_key -eq 1 ]]; then
    while true; do
      PRIVKEY_SAVED="$PRIVKEY"
      read -rp "Enter DNSTT private key (hex, 64 chars). Leave empty to keep current or generate new key: " PRIVKEY_INPUT
      PRIVKEY_TRIMMED="$(echo -n "$PRIVKEY_INPUT" | tr -d '[:space:]')"
      if [[ -z "$PRIVKEY_TRIMMED" ]]; then
        break
      fi
      PRIVKEY="$PRIVKEY_TRIMMED"
      if [[ "$PRIVKEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
        derive_pubkey
        if [[ -n "$PUBKEY" ]] && [[ "$PUBKEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
          break
        fi
      fi
      PRIVKEY="$PRIVKEY_SAVED"
      echo "Invalid private key. Key must be 64 hex characters and must derive a valid public key." >&2
    done
    if [[ -z "$PRIVKEY" ]]; then
      echo "Generating transport key (DNSTT)..."
      KEYS=$(docker run --rm $DNSTT_SERVER_IMAGE -gen-key)
      PRIVKEY=$(echo "$KEYS" | grep 'privkey' | awk '{print $2}')
      derive_pubkey
    fi
  fi
}

# ===========================
# Save config to file
# ===========================
save_config() {
  {
    echo "CONFIG_VERSION=\"$DNSTUN_VERSION\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "PREFIX=\"$PREFIX\""
    echo "NUM_SERVERS=\"$NUM_SERVERS\""
    echo "AUTH_USER=\"$AUTH_USER\""
    echo "AUTH_PASS=\"$AUTH_PASS\""
    echo "PRIVKEY=\"$PRIVKEY\""
    printf "DOMAINS=("
    for d in "${DOMAINS[@]}"; do printf "\"%s\" " "$d"; done
    echo ")"
    printf "PROTOCOLS=("
    for t in "${PROTOCOLS[@]}"; do printf "\"%s\" " "$t"; done
    echo ")"
    printf "TRANSPORTS=("
    for t in "${TRANSPORTS[@]}"; do printf "\"%s\" " "$t"; done
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
  cat <<EOF > "$DNS_LB_YML"
# Generated by dnstun-ezpz $DNSTUN_VERSION
logging:
  level: "error"

global:
  listen_address: "0.0.0.0:53"
  read_timeout: "60s"
  default_dns_behavior:
    mode: "drop"

protocols:
EOF
  # Port per domain: TRANSPORT_FIRST_PORT + domain index
  # DNSTT pools
  local has_dnstt=0
  for i in "${!DOMAINS[@]}"; do [[ "${TRANSPORTS[$i]}" == "dnstt" ]] && { has_dnstt=1; break; }; done
  if [[ $has_dnstt -eq 1 ]]; then
    echo "  dnstt:" >> "$DNS_LB_YML"
    echo "    pools:" >> "$DNS_LB_YML"
    for i in "${!DOMAINS[@]}"; do
      [[ "${TRANSPORTS[$i]}" != "dnstt" ]] && continue
      DOMAIN=${DOMAINS[$i]}
      CURRENT_PORT=$((TRANSPORT_FIRST_PORT + i))
      cat <<EOF >> "$DNS_LB_YML"
      - name: "$DOMAIN"
        domain_suffix: "$DOMAIN"
        backends:
EOF
      # Backend id/address use server id (1..NUM_SERVERS) so subdomain matches: s1, s2, ...
      for ((server_id=1;server_id<=NUM_SERVERS;server_id++)); do
        echo "          - id: \"${PREFIX}${server_id}\"" >> "$DNS_LB_YML"
        echo "            address: \"${PREFIX}${server_id}.$BASE_DOMAIN:$CURRENT_PORT\"" >> "$DNS_LB_YML"
      done
    done
  fi
  # Slipstream pools: lb_id must match server id (subdomain number), e.g. lb_id 2 -> s2
  local has_slipstream=0
  for i in "${!DOMAINS[@]}"; do [[ "${TRANSPORTS[$i]}" == "slipstream" ]] && { has_slipstream=1; break; }; done
  if [[ $has_slipstream -eq 1 ]]; then
    echo "  slipstream:" >> "$DNS_LB_YML"
    echo "    pools:" >> "$DNS_LB_YML"
    for i in "${!DOMAINS[@]}"; do
      [[ "${TRANSPORTS[$i]}" != "slipstream" ]] && continue
      DOMAIN=${DOMAINS[$i]}
      CURRENT_PORT=$((TRANSPORT_FIRST_PORT + i))
      cat <<EOF >> "$DNS_LB_YML"
      - name: "$DOMAIN"
        domain_suffix: "$DOMAIN"
        backends:
EOF
      for ((server_id=1;server_id<=NUM_SERVERS;server_id++)); do
        echo "          - id: \"${PREFIX}${server_id}\"" >> "$DNS_LB_YML"
        echo "            address: \"${PREFIX}${server_id}.$BASE_DOMAIN:$CURRENT_PORT\"" >> "$DNS_LB_YML"
        echo "            lb_id: $server_id" >> "$DNS_LB_YML"
      done
    done
  fi
}
# ===========================
# Generate docker-compose.yml
# ===========================
generate_docker_compose_yml() {
  if [[ ! "${SERVER_ID:-}" =~ ^[0-9]+$ ]] || [[ "$SERVER_ID" -lt 1 ]] || [[ "$SERVER_ID" -gt 255 ]]; then
    echo "Error: SERVER_ID is required (1-255). Reconfigure the cluster (option 2) to set this server's ID." >&2
    exit 1
  fi
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

  # Add transport services (DNSTT or Slipstream per domain); port = TRANSPORT_FIRST_PORT + domain index; container index per transport
  SLIPSTREAM_VOLUMES=()
  DNSTT_IDX=0
  SLIPSTREAM_IDX=0
  for i in "${!DOMAINS[@]}"; do
    DOMAIN=${DOMAINS[$i]}
    PROTOCOL=${PROTOCOLS[$i]}
    TRANSPORT=${TRANSPORTS[$i]}
    LOCAL_PORT=$((TRANSPORT_FIRST_PORT + i))
    TARGET_ADDR="127.0.0.1:$([ "$PROTOCOL" == "ssh" ] && echo $SSHD_PORT || echo $SINGBOX_SOCKS_PORT)"

    if [[ "$TRANSPORT" == "dnstt" ]]; then
      ((DNSTT_IDX++)) || true
      CONTAINER_NAME="dnstt-$DNSTT_IDX"
      BACKEND="$DOMAIN $TARGET_ADDR"
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
    else
      ((SLIPSTREAM_IDX++)) || true
      CONTAINER_NAME="slipstream-$SLIPSTREAM_IDX"
      VOL_NAME="slipstream-$SLIPSTREAM_IDX-data"
      SLIPSTREAM_VOLUMES+=("$VOL_NAME")
      cat <<EOF >> "$DOCKER_COMPOSE_YML"

  $CONTAINER_NAME:
    image: $SLIPSTREAM_SERVER_IMAGE
    command: >
      --dns-listen-host 0.0.0.0
      --dns-listen-port $LOCAL_PORT
      --domain $DOMAIN
      --target-address $TARGET_ADDR
      --quic-lb-server-id $SERVER_ID
      --reset-seed /var/lib/slipstream/reset-seed
      --cert /var/lib/slipstream/server.cert
      --key /var/lib/slipstream/server.key
    restart: always
    network_mode: "host"
    volumes:
      - $VOL_NAME:/var/lib/slipstream
EOF
    fi
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
      AUTH_USER_ID: "$AUTH_UID"
    volumes:
      - $ROUTE_SETUP_SH:/usr/local/bin/route_setup.sh:ro
    entrypoint: ["/usr/local/bin/route_setup.sh"]
    restart: always
EOF
  if [[ ${#SLIPSTREAM_VOLUMES[@]} -gt 0 ]]; then
    echo "volumes:" >> "$DOCKER_COMPOSE_YML"
    for v in "${SLIPSTREAM_VOLUMES[@]}"; do
      echo "  $v: {}" >> "$DOCKER_COMPOSE_YML"
    done
  fi
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
    {"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": 0, "users": [{"username": "username", "password": "password"}]}
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
    --arg auth_user "$AUTH_USER" \
    --arg auth_pass "$AUTH_PASS" \
    '.inbounds[0].listen_port = $listen_port |
     .inbounds[0].users = [{"username": $auth_user, "password": $auth_pass}] |
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
  ip rule del uidrange ${AUTH_USER_ID}-${AUTH_USER_ID} table 200 2>/dev/null || true
  ip route del default dev wg0 table 200 2>/dev/null || true
}
trap cleanup EXIT TERM INT

while ! ip link show wg0 >/dev/null 2>&1; do
  sleep 1
done

if ! ip route show table 200 2>/dev/null | grep -q "^default .* dev wg0"; then
  ip route add default dev wg0 table 200
fi

if ! ip rule show | grep -q "uidrange ${AUTH_USER_ID}-${AUTH_USER_ID} .* table 200"; then
  ip rule add uidrange ${AUTH_USER_ID}-${AUTH_USER_ID} table 200
fi

while true; do
  sleep 3600 &
  wait $!
done
ROUTEEOF
  chmod +x "$ROUTE_SETUP_SH"
}

# ===========================
# Create tunnel user for SSH (sets AUTH_UID)
# ===========================
# When reconfiguring: updates password if user exists; removes old user if username changed.
create_ssh_user() {
  if ! id -u "$AUTH_USER" &>/dev/null; then
    useradd -r -d /var/empty -s /usr/sbin/nologin -M -p "$(openssl passwd -6 "$AUTH_PASS")" "$AUTH_USER"
  else
    usermod -p "$(openssl passwd -6 "$AUTH_PASS")" "$AUTH_USER"
  fi
  AUTH_UID=$(id -u "$AUTH_USER" 2>/dev/null)
  if [[ -n "${OLD_AUTH_USER:-}" && "${OLD_AUTH_USER}" != "$AUTH_USER" ]] && id -u "$OLD_AUTH_USER" &>/dev/null; then
    userdel "$OLD_AUTH_USER" || echo "Warning: failed to delete old user $OLD_AUTH_USER" >&2
  fi
}

# ===========================
# SSH user match config
# ===========================
# Writes $SSHD_CONF so sshd picks it up (Include in sshd_config.d).
generate_ssh_config() {
  mkdir -p "$SSHD_DIR"
  cat <<EOF > "$SSHD_CONF"
Match User $AUTH_USER Address 127.0.0.1
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