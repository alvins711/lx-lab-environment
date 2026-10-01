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

# Maximum number of sandboxes this script will create in one run (override via .env)
MAX_USERS="${MAX_USERS:-40}"

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

# ==========================================================================
# Pre-flight: don't deploy blindly on top of a lab that is already running.
# Doing so leaves the old containers in place (or fails outright on a
# container-name conflict), and reuses the old workspace folders, so the
# result is neither the old lab nor a clean one.
# ==========================================================================
preflight_existing_lab() {
    local containers stale_dirs answer

    containers=$(docker ps -a --filter "name=workstation_${USER_PREFIX}" \
        --format '{{.Names}} ({{.State}})' 2>/dev/null) || true
    stale_dirs=$(ls -d ./workspaces/"${USER_PREFIX}"* 2>/dev/null) || true

    # Nothing from a previous run — clean slate, carry on.
    if [ -z "$containers" ] && [ -z "$stale_dirs" ] && [ ! -f "$DYNAMIC_COMPOSE" ]; then
        return 0
    fi

    echo ""
    echo "⚠ An existing lab deployment was detected on this host:"

    if [ -n "$containers" ]; then
        echo ""
        echo "  Containers:"
        echo "$containers" | sed 's/^/    /'
    fi

    if [ -n "$stale_dirs" ]; then
        echo ""
        echo "  Workspace folders (the compose file is generated from these, so each"
        echo "  one becomes a container regardless of the count you enter next):"
        echo "$stale_dirs" | sed 's|^\./workspaces/|    |'
    fi

    echo ""
    echo "Deploying on top of this reuses those folders and recreates the containers."
    echo "It will not give you a clean lab."
    echo ""
    echo "1) Tear the old lab down first, then deploy fresh (recommended)"
    echo "2) Deploy anyway, on top of what is already there"
    echo "3) Abort"

    while true; do
        read -p "Select an option (1-3): " answer
        case "$answer" in
            1)
                echo ""
                echo "Running ./cleanup_lab.sh ..."
                if ! ./cleanup_lab.sh; then
                    echo ""
                    echo "⚠ cleanup_lab.sh reported an error — the old lab may only be"
                    echo "  partially torn down."
                    read -p "Continue with the deployment anyway? (y/N): " answer
                    if ! [[ "$answer" =~ ^[Yy]$ ]]; then
                        echo "Aborted."
                        exit 1
                    fi
                fi
                echo ""
                echo "Continuing with a fresh deployment."
                return 0
                ;;
            2)
                echo "Continuing on top of the existing deployment."
                return 0
                ;;
            3)
                echo "Aborted. Nothing was changed."
                exit 0
                ;;
            *)
                echo "❌ Error: Please enter 1, 2, or 3."
                ;;
        esac
    done
}

# Warn when more workspace folders exist than the number of sandboxes just
# requested. They would be deployed as containers (the compose file is built
# from the folders on disk) but would have no Guacamole login, because the
# login map only covers the requested range.
check_extra_workspaces() {
    local extras=() folder base num answer

    for folder in ./workspaces/"${USER_PREFIX}"*; do
        [ -d "$folder" ] || continue
        base=$(basename "$folder")
        num=$(echo "$base" | sed "s/^${USER_PREFIX}//")
        if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$((10#$num))" -gt "$USER_COUNT" ]; then
            extras+=("$base")
        fi
    done

    if [ "${#extras[@]}" -eq 0 ]; then
        return 0
    fi

    echo ""
    echo "⚠ These workspace folders exist beyond the $USER_COUNT sandbox(es) you requested:"
    printf '    %s\n' "${extras[@]}"
    echo ""
    echo "They would be deployed as containers, but would have no Guacamole login."
    echo ""
    echo "1) Delete these extra workspace folders (their student files are lost)"
    echo "2) Keep and deploy them anyway"
    echo "3) Abort"

    while true; do
        read -p "Select an option (1-3): " answer
        case "$answer" in
            1)
                for base in "${extras[@]}"; do
                    rm -rf "./workspaces/${base:?}"
                    rm -rf "./claude_config/${base:?}"
                    echo "  removed $base"
                done
                return 0
                ;;
            2)
                echo "Keeping the extra workspaces."
                return 0
                ;;
            3)
                echo "Aborted. Nothing was changed."
                exit 0
                ;;
            *)
                echo "❌ Error: Please enter 1, 2, or 3."
                ;;
        esac
    done
}

preflight_existing_lab

# Prompt for the number of user sandboxes needed
read -p "Enter the number of student sandboxes to deploy: " USER_COUNT

# Validate user input is a positive integer within a sane range
if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] || [ "$USER_COUNT" -lt 1 ] || [ "$USER_COUNT" -gt "$MAX_USERS" ]; then
   echo "Error: Enter a whole number between 1 and $MAX_USERS."
   exit 1
fi

check_extra_workspaces

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

    # Provision the persistent home + .claude config directories and seed the
    # shell profile (shared with manage_users.sh via lab_lib.sh)
    provision_user_dirs "$USER_NAME"

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

# Run both files concurrently, passing the exported environment variables safely.
# --remove-orphans clears out containers left behind by a previous deployment
# that had more users than this one.
docker compose -f docker-compose.yml -f docker-compose.users.yml up -d --build --remove-orphans

echo ""
echo "=================================================="
echo " Lab is live! Connect to:"
echo " https://$DETECTED_IP/guacamole/"
echo "=================================================="
