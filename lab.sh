#!/bin/bash
# lab.sh
#
# Single entry point for the lab control scripts, so you don't need to
# remember which of deploy_lab.sh / manage_users.sh / cleanup_lab.sh does
# what, or run them from the right directory. It just menus into the real
# scripts — it doesn't duplicate any of their logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Make sure the scripts this wraps actually exist and are runnable before
# offering them in the menu.
for script in deploy_lab.sh manage_users.sh cleanup_lab.sh; do
    if [ ! -f "$script" ]; then
        echo "❌ Error: $script not found in $SCRIPT_DIR."
        exit 1
    fi
    if [ ! -x "$script" ]; then
        chmod +x "$script"
    fi
done

print_menu() {
    echo ""
    echo "=========================================================="
    echo "                Claude Code Lab Control"
    echo "=========================================================="
    echo "1) Deploy the lab            (deploy_lab.sh)"
    echo "2) Manage users              (manage_users.sh)"
    echo "3) Tear down / clean up      (cleanup_lab.sh)"
    echo "4) Exit"
    echo "=========================================================="
}

# Run one of the wrapped scripts without letting its exit code kill this
# wrapper (set -e would otherwise end the whole menu the first time a
# sub-script legitimately exits non-zero, e.g. bad input or "user already
# exists").
run_step() {
    local script="$1"
    echo ""
    if ! "./$script"; then
        echo ""
        echo "⚠ $script exited with an error — see output above."
    fi
    echo ""
    read -p "Press Enter to return to the menu..." _
}

while true; do
    print_menu
    read -p "Select an option (1-4): " CHOICE

    case "$CHOICE" in
        1) run_step "deploy_lab.sh" ;;
        2) run_step "manage_users.sh" ;;
        3) run_step "cleanup_lab.sh" ;;
        4)
            echo "Goodbye."
            exit 0
            ;;
        *)
            echo "❌ Error: Invalid selection. Please enter 1, 2, 3, or 4."
            ;;
    esac
done
