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
CPU_LIMIT="${CPU_LIMIT:-0.5}"
MEM_LIMIT="${MEM_LIMIT:-512m}"

# Credential configuration (override via .env)
USER_PREFIX="${USER_PREFIX:-user}"
PASS_PREFIX="${PASS_PREFIX:-user}"
SSH_PASSWORD="${SSH_PASSWORD:-password123}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-password123}"

# Claude endpoint configuration (override via .env; left empty by default —
# matches deploy_lab.sh, and avoids baking a real personal endpoint into the script)
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"

# Automatically detect the machine's primary local IP address for the roster view
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}') || true
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP=$(hostname -I | awk '{print $1}') || true
fi

# Ensure core files exist before running modifications
if [ ! -f "$DYNAMIC_COMPOSE" ] || [ ! -f "$GUAC_MAPPING" ]; then
    echo "❌ Error: Lab must be running or initialized via ./deploy_lab.sh first."
    exit 1
fi

echo "=== Claude Lab Individual User Manager ==="

# Infinite loop that only breaks when a correct choice (1, 2, or 3) is verified
while true; do
    echo "1) Add a new user"
    echo "2) Delete an existing user"
    echo "3) View active roster list"
    read -p "Select an option (1-3): " CHOICE

    case "$CHOICE" in
        1|2|3)
            break
            ;;
        *)
            echo -e "❌ Error: Invalid selection. Please enter 1, 2, or 3.\n"
            ;;
    esac
done

# ==========================================
# OPTION 1: ADD INDIVIDUAL USER (Requires 2 digits)
# ==========================================
if [ "$CHOICE" == "1" ]; then
    while true; do
        read -p "Enter new user ID (Must be exactly 2 digits, e.g., 02 or 13): " USER_ID

        # Regex validation enforcing exactly two numeric digits
        if [[ "$USER_ID" =~ ^[0-9]{2}$ ]]; then
            break
        else
            echo "❌ Error: Input must be exactly 2 digits (e.g., use '02' instead of '2')."
        fi
    done

    USER_NAME="${USER_PREFIX}$USER_ID"
    USER_PASS="${PASS_PREFIX}$USER_ID"

    if grep -q "username=\"$USER_NAME\"" "$GUAC_MAPPING"; then
        echo "⚠️ User $USER_NAME already exists in Guacamole configuration."
        exit 1
    fi

    echo "Adding $USER_NAME to the running lab environment..."

    # 1. Setup filesystem home directory paths
    mkdir -p "./workspaces/$USER_NAME"
    chmod -R 777 "./workspaces/$USER_NAME"

    # Seed the shell profile into the persistent home directory (only if absent)
    if [ ! -f "./workspaces/$USER_NAME/.bashrc" ]; then
        cp "custom_bashrc.tmpl" "./workspaces/$USER_NAME/.bashrc"
    fi
    if [ ! -f "./workspaces/$USER_NAME/.profile" ]; then
        cp "custom_profile.tmpl" "./workspaces/$USER_NAME/.profile"
    fi

    # 2. Inject the new <authorize> block immediately before the closing
    # </user-mapping> tag. Targeting that specific line with awk is safer
    # than the previous whole-file string replace, which would have silently
    # corrupted the file if that literal text ever appeared more than once.
    NEW_USER_XML=$(cat <<XMLBLOCK
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
XMLBLOCK
)

    awk -v block="$NEW_USER_XML" '
        /<\/user-mapping>/ { print block }
        { print }
    ' "$GUAC_MAPPING" > "${GUAC_MAPPING}.tmp" && mv "${GUAC_MAPPING}.tmp" "$GUAC_MAPPING"

    # 3. Rebuild the compose file from disk state (shared with deploy_lab.sh
    # via lab_lib.sh, so this user gets exactly the same service definition
    # as everyone deployed initially — no more args/env drift between scripts).
    rebuild_dynamic_compose

    # 4. Boot container service up online
    docker compose -f docker-compose.yml -f docker-compose.users.yml up -d --build "workstation_$USER_NAME"

    echo "✔ Successfully added $USER_NAME!"
    echo "Credentials -> User: $USER_NAME | Pass: $USER_PASS"

# ==========================================
# OPTION 2: DELETE INDIVIDUAL USER (Accepts 1 digit)
# ==========================================
elif [ "$CHOICE" == "2" ]; then
    while true; do
        read -p "Enter user ID to delete (1 or 2 digits, e.g., 2 or 12): " USER_ID

        # Validate that input is numeric
        if [[ "$USER_ID" =~ ^[0-9]+$ ]]; then
            break
        else
            echo "❌ Error: Input must be a valid number."
        fi
    done

    # Automatically pad with a leading zero if a single digit is passed (e.g., 2 -> 02)
    USER_NUM=$(printf "%02g" "$USER_ID")
    USER_NAME="${USER_PREFIX}$USER_NUM"

    if [ ! -d "./workspaces/$USER_NAME" ]; then
        echo "❌ Error: User $USER_NAME workspace path not found on disk."
        exit 1
    fi

    echo "Removing $USER_NAME from the environment..."

    # 1. Instantly tear container and configuration volume down out of Docker.
    # Best-effort: an already-stopped container, or a volume that was never
    # created (bind mounts are used for claude_config, not named volumes),
    # should not abort the rest of the cleanup below.
    docker compose -f docker-compose.yml -f docker-compose.users.yml stop "workstation_$USER_NAME" || true
    docker rm -f "workstation_$USER_NAME" || true
    docker volume rm "bc_lab_v3_claude_config_$USER_NAME" 2>/dev/null \
        || docker volume rm "${PWD##*/}_claude_config_$USER_NAME" 2>/dev/null \
        || true

    # 2. Wipe XML matching credential block array lines safely preserving the inode
    sed "/<authorize username=\"$USER_NAME\"/,/<\/authorize>/d" "$GUAC_MAPPING" > "${GUAC_MAPPING}.tmp"
    cat "${GUAC_MAPPING}.tmp" > "$GUAC_MAPPING"
    rm -f "${GUAC_MAPPING}.tmp"

    echo ""
    read -p "Do you want to permanently delete all user's code files from the host? (y/N): " PURGE_DATA

    if [[ "$PURGE_DATA" =~ ^[Yy]$ ]]; then
        echo "Purging host workspace directories..."
        rm -rf "./workspaces/$USER_NAME"
        rm -rf "./claude_config/$USER_NAME"
        echo "✔ Workspaces completely scrubbed."
    else
        echo "🛈 Workspace folder contents preserved inside ./workspaces and ./claude_config."
    fi

    echo "=== Environment Deleted ==="

    # 3. Rebuild the compose file from whatever workspace folders remain
    rebuild_dynamic_compose

    echo "✔ Successfully removed $USER_NAME completely from active roster."

# ==========================================
# OPTION 3: VIEW ACTIVE ROSTER LIST
# ==========================================
elif [ "$CHOICE" == "3" ]; then
    echo -e "\n=========================================================================="
    echo "                      CURRENTLY DEPLOYED LAB ROSTER                       "
    echo "=========================================================================="
    printf "%-12s | %-12s | %-42s\n" "Username" "Password" "Connection URL"
    echo "--------------------------------------------------------------------------"

    USER_FOUND=false
    for folder in ./workspaces/${USER_PREFIX}*; do
        if [ -d "$folder" ]; then
            USER_FOUND=true
            CURRENT_NUM=$(basename "$folder" | sed "s/^${USER_PREFIX}//")
            ROSTER_USER="${USER_PREFIX}$CURRENT_NUM"
            ROSTER_PASS="${PASS_PREFIX}$CURRENT_NUM"
            ROSTER_URL="https://$DETECTED_IP/guacamole/"

            printf "%-12s | %-12s | %-42s\n" "$ROSTER_USER" "$ROSTER_PASS" "$ROSTER_URL"
        fi
    done

    if [ "$USER_FOUND" = false ]; then
        echo "   No active student workspaces found deployed on this machine."
    fi
    echo -e "==========================================================================\n"
fi
