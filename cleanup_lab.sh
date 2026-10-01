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
LAB_NETWORK="guac_lab_net"

# Credential configuration (override via .env)
USER_PREFIX="${USER_PREFIX:-user}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-password123}"

echo "=== Lab Stack Teardown ==="

if [ -f "$DYNAMIC_COMPOSE" ]; then
    # ----------------------------------------------------------------------
    # Normal path: the deployment layout exists, so tear down through compose
    # ----------------------------------------------------------------------
    echo ""
    echo "Full teardown will also delete the locally-built lab images (--rmi local)"
    echo "and the named config volumes (-v) tied to docker-compose.users.yml."
    read -p "Proceed with full teardown, including images and volumes? (y/N): " CONFIRM_TEARDOWN

    if [[ "$CONFIRM_TEARDOWN" =~ ^[Yy]$ ]]; then
        echo "Spinning down running user sandboxes and removing configuration volumes and images..."
        # The -v flag clears out the named volumes so git locks/plugins completely reset for the next class
        docker compose -f docker-compose.yml -f docker-compose.users.yml down --remove-orphans -v --rmi local
    else
        echo "Stopping containers only — images and volumes are kept."
        docker compose -f docker-compose.yml -f docker-compose.users.yml down --remove-orphans
    fi
else
    # ----------------------------------------------------------------------
    # Fallback path: the compose file is gone (e.g. a previous partial
    # cleanup removed it) but containers from that deployment may still be
    # running. Compose can no longer see them, so they have to be removed
    # directly — otherwise they linger forever and the next deploy collides
    # with their container names.
    # ----------------------------------------------------------------------
    echo "⚠ Active configuration layout ($DYNAMIC_COMPOSE) not found."
    echo "  Checking for containers left behind by a previous deployment..."

    STRAY=$(docker ps -a --filter "name=workstation_${USER_PREFIX}" --format '{{.Names}}' 2>/dev/null) || true

    if [ -z "$STRAY" ]; then
        echo "  None found — nothing to tear down."
        exit 0
    fi

    echo ""
    echo "  These containers still exist but are no longer described by any compose"
    echo "  file, so they can only be removed directly:"
    echo "$STRAY" | sed 's/^/    /'
    echo ""
    read -p "Remove them now? (y/N): " CONFIRM_STRAY

    if [[ "$CONFIRM_STRAY" =~ ^[Yy]$ ]]; then
        echo "$STRAY" | xargs -r docker rm -f
        echo "✔ Removed leftover containers."
    else
        echo "🛈 Leftover containers left in place."
    fi
fi

# Explicitly prune the persistent shared network segment bridge interface
if docker network ls | grep -q "$LAB_NETWORK"; then
    echo "Purging network architecture interface: $LAB_NETWORK..."
    if ! docker network rm "$LAB_NETWORK" 2>/dev/null; then
        echo "⚠ Could not remove $LAB_NETWORK — something is still attached to it."
    fi
fi

echo "Resetting web mappings and clearing dynamic environments..."
rm -f "$DYNAMIC_COMPOSE"

# Clear out user lists, protecting the root admin credentials
if [ -f "$GUAC_MAPPING" ]; then
    cat << EOF > "$GUAC_MAPPING"
<user-mapping>
    <authorize username="guacadmin" password="$ADMIN_PASSWORD">
    </authorize>
</user-mapping>
EOF
    echo "✔ Guacamole web mapping stripped back to standard admin template."
fi

# Decide what happens to the student work on disk: archive it under a
# timestamped folder, leave it for the next class to resume, or delete it.
# (Runs after the containers are down, so nothing is still bind-mounted.)
mapfile -t USERS_ON_DISK < <(collect_users_on_disk)

if [ "${#USERS_ON_DISK[@]}" -gt 0 ]; then
    prompt_user_data_disposition "teardown" "${USERS_ON_DISK[@]}"
else
    echo "🛈 No student work directories found on disk."
fi

echo "=== Environment Deleted ==="
