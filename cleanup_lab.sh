#!/bin/bash

DYNAMIC_COMPOSE="docker-compose.users.yml"
GUAC_MAPPING="./config/guacamole/user-mapping.xml"

echo "=== Claude Code Lab Stack Teardown ==="

# Exit if no dynamic user deployment layout is found
if [ ! -f "$DYNAMIC_COMPOSE" ]; then
    echo "⚠ Active configuration layout ($DYNAMIC_COMPOSE) not found."
    exit 0
fi

echo "Spinning down running user sandboxes and removing configuration volumes..."
# The -v flag clears out the named volumes so git locks/plugins completely reset for the next class
docker compose -f docker-compose.yml -f docker-compose.users.yml down --remove-orphans -v

echo "Resetting web mappings and clearing dynamic environments..."
rm -f "$DYNAMIC_COMPOSE"

# Clear out user lists, protecting the root admin credentials
if [ -f "$GUAC_MAPPING" ]; then
    cat << EOF > $GUAC_MAPPING
<user-mapping>
    <authorize username="guacadmin" password="password123">
    </authorize>
</user-mapping>
EOF
    echo "✔ Guacamole web mapping stripped back to standard admin template."
fi

echo ""
read -p "Do you want to permanently delete all student code files from the host? (y/N): " PURGE_DATA

if [[ "$PURGE_DATA" =~ ^[Yy]$ ]]; then
    echo "Purging host workspace directories..."
    rm -rf ./workspaces/user*
    echo "✔ Workspaces completely scrubbed."
else
    echo "🛈 Workspace folder contents preserved inside ./workspaces."
fi

echo "=== Environment Sanitized ==="

