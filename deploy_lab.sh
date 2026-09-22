#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lab_lib.sh"

# Load environment configuration from .env if present
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# 1. Automatically detect the machine's primary local IP address
# Works reliably on Debian, Ubuntu, AlmaLinux, RHEL, and Raspberry Pi OS
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}') || true

# Fallback mechanism if the route command fails (e.g. no internet route)
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP=$(hostname -I | awk '{print $1}') || true
fi

if [ -z "$DETECTED_IP" ]; then
    echo "⚠ Could not auto-detect a local IP address. The connection URL printed at the end may be wrong."
fi

echo "=================================================="
echo " Detected Machine Local IP: $DETECTED_IP"
echo "=================================================="
export HOST_IP="$DETECTED_IP"

# Maximum number of sandboxes this script will create in one run (override via .env)
MAX_USERS="${MAX_USERS:-40}"

# Prompt for the number of user sandboxes needed
read -p "Enter the number of student sandboxes to deploy: " USER_COUNT

# Validate user input is a positive integer within a sane range
if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ] || [ "$USER_COUNT" -gt "$MAX_USERS" ]; then
   echo "Error: Enter a whole number between 1 and $MAX_USERS."
   exit 1
fi

DYNAMIC_COMPOSE="docker-compose.users.yml"
GUAC_MAPPING="./config/guacamole/user-mapping.xml"

# Resource constraint variables (override via .env)
CPU_LIMIT="${CPU_LIMIT:-0.5}"
MEM_LIMIT="${MEM_LIMIT:-512m}"

# Credential configuration (override via .env)
USER_PREFIX="${USER_PREFIX:-user}"
PASS_PREFIX="${PASS_PREFIX:-user}"
SSH_PASSWORD="${SSH_PASSWORD:-password123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-password123}"

# Claude endpoint configuration (optional via .env, may be empty)
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"

# Ensure host directory structures exist safely
mkdir -p "./config/guacamole"

# Ensure the shared Docker network exists before booting containers
if ! docker network ls | grep -q "guac_lab_net"; then
    echo "Creating external Docker network: guac_lab_net..."
    docker network create guac_lab_net
fi

# Initialize the user-mapping.xml file layout
cat << EOF > "$GUAC_MAPPING"
<user-mapping>
    <!-- Default Infrastructure Administrator Account -->
    <authorize username="guacadmin" password="$ADMIN_PASSWORD">
    </authorize>

EOF

echo "Generating access keys and environment spaces..."

# Build unique profiles per student sandbox.
# NOTE: secrets (SSH_PASSWORD / ANTHROPIC_*) are only ever passed as runtime
# `environment:` values (see lab_lib.sh) — never as build args, so they are
# never baked into the image layer history.
for i in $(seq -f "%02g" 1 "$USER_COUNT"); do
    USER_NAME="${USER_PREFIX}$i"
    USER_PASS="${PASS_PREFIX}$i"

    # Provision persistent home directory folders with full host read/write permissions
    mkdir -p "./workspaces/$USER_NAME"
    chmod -R 777 "./workspaces/$USER_NAME"

    # Seed the shell profile into the persistent home directory (only if absent)
    if [ ! -f "./workspaces/$USER_NAME/.bashrc" ]; then
        cp "custom_bashrc.tmpl" "./workspaces/$USER_NAME/.bashrc"
    fi
    if [ ! -f "./workspaces/$USER_NAME/.profile" ]; then
        cp "custom_profile.tmpl" "./workspaces/$USER_NAME/.profile"
    fi

    # Provision local-disk directory for persistent .claude config
    mkdir -p "./claude_config/$USER_NAME"
    chmod -R 777 "./claude_config/$USER_NAME"

    # Map the unique user account straight into Guacamole via internal container DNS
    cat << EOF >> "$GUAC_MAPPING"
    <!-- Access Profile for $USER_NAME -->
    <authorize username="$USER_NAME" password="$USER_PASS">
        <connection name="Workstation Sandbox ($USER_NAME)">
            <protocol>ssh</protocol>
            <param name="hostname">workstation_$USER_NAME</param>
            <param name="port">22</param>
            <param name="username">labuser</param>
            <param name="password">$SSH_PASSWORD</param>
        </connection>
    </authorize>

EOF
done

# Close the XML structure properly
echo "</user-mapping>" >> "$GUAC_MAPPING"

# Generate the dynamic compose file from whatever workspace folders now exist
# on disk (shared with manage_users.sh via lab_lib.sh, so the layout can't drift).
rebuild_dynamic_compose

echo "✔ Generated $USER_COUNT configurations in $DYNAMIC_COMPOSE"
echo "✔ Updated web terminal maps in $GUAC_MAPPING"
echo "Initializing the environment stack..."

# Run both files concurrently, passing the exported environment variables safely
docker compose -f docker-compose.yml -f docker-compose.users.yml up -d --build

echo ""
echo "=================================================="
echo " Lab is live! Connect to:"
echo " https://$DETECTED_IP/guacamole/"
echo "=================================================="
