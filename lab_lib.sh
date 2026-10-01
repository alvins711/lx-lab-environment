#!/bin/bash
# lab_lib.sh
#
# Shared helpers for deploy_lab.sh, manage_users.sh and cleanup_lab.sh. This
# file is meant to be sourced, not executed directly — it defines functions
# that rely on variables the calling script has already set: DYNAMIC_COMPOSE,
# USER_PREFIX, CPU_LIMIT, MEM_LIMIT, SSH_PASSWORD, ANTHROPIC_BASE_URL,
# ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL.
#
# Having a single copy of the "dynamic compose file" layout, the per-user
# directory provisioning, and the work-directory disposition prompt means the
# control scripts can no longer drift out of sync with each other. Previously
# each script hand-rolled its own copy of these blocks, and manage_users.sh's
# copies silently differed from deploy_lab.sh's, so a user added later was
# not set up the same way as a user created at initial deploy.

# Emit one docker-compose service block for a single student workstation.
#
# Secrets are only ever passed as runtime `environment:` values, never as
# build `args:` — build args get baked into the image's layer history and
# are recoverable from the image indefinitely (e.g. via `docker history`),
# even after rotation. Runtime environment values are not.
_emit_service_block() {
    local user_name="$1"
    cat <<EOF
  workstation_${user_name}:
    build:
      context: .
      dockerfile: Dockerfile.lab
    container_name: workstation_${user_name}
    hostname: workstation_${user_name}
    environment:
      - CLAUDE_CONFIG_DIR=/home/labuser/.claude
      - SSH_PASSWORD=${SSH_PASSWORD}
      - ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}
      - ANTHROPIC_MODEL=${ANTHROPIC_MODEL}
    volumes:
      - ./workspaces/${user_name}:/home/labuser
      - ./claude_config/${user_name}:/home/labuser/.claude
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT}'
          memory: ${MEM_LIMIT}
    networks:
      - guac_lab_net
    restart: unless-stopped

EOF
}

# Make one directory writable by the container's labuser (uid 1001), which
# does not match the host user's uid — hence the permissive mode.
#
# Warns instead of aborting when the host user doesn't own the directory
# (chmod requires ownership of the target, unlike rm, which only needs write
# permission on the parent). That happens when Docker created the directory
# as root on an earlier run.
_make_writable() {
    local dir="$1"
    if ! chmod 777 "$dir" 2>/dev/null; then
        echo "⚠ Could not chmod $dir — it is not owned by $(id -un). Continuing."
        echo "  If the sandbox then can't write to it, run:"
        echo "      sudo chown -R $(id -u):$(id -g) $dir"
    fi
}

# Create the on-disk folders for one student: the persistent home directory
# and the persistent .claude config directory, with the shell profile seeded.
#
# NOTE: deliberately NOT `chmod -R`. Recursing fails on every re-deploy:
#   * ./workspaces/<user>/.claude is created by Docker as a root-owned
#     mountpoint, because ./claude_config/<user> is mounted *inside* the
#     /home/labuser mount, and
#   * files under ./claude_config/<user> are created by the container as
#     uid 1001,
# and chmod requires ownership of each file it touches, so the host user can
# chmod neither. Neither needs it: the container already owns what it
# created, and only the directories themselves have to be writable.
provision_user_dirs() {
    local user_name="$1"

    # Persistent home directory (mounted at /home/labuser)
    mkdir -p "./workspaces/$user_name"
    _make_writable "./workspaces/$user_name"

    # Persistent .claude config directory (mounted at /home/labuser/.claude)
    mkdir -p "./claude_config/$user_name"
    _make_writable "./claude_config/$user_name"

    # Seed the shell profile into the persistent home directory (only if absent)
    if [ ! -f "./workspaces/$user_name/.bashrc" ]; then
        cp "custom_bashrc.tmpl" "./workspaces/$user_name/.bashrc"
        chmod 666 "./workspaces/$user_name/.bashrc"
    fi
    if [ ! -f "./workspaces/$user_name/.profile" ]; then
        cp "custom_profile.tmpl" "./workspaces/$user_name/.profile"
        chmod 666 "./workspaces/$user_name/.profile"
    fi
}

# List every student that currently has data on disk, across both trees,
# de-duplicated. Reads ./workspaces and ./claude_config because a user can
# have one without the other.
collect_users_on_disk() {
    local folder
    {
        for folder in ./workspaces/"${USER_PREFIX}"* ./claude_config/"${USER_PREFIX}"*; do
            [ -d "$folder" ] || continue
            basename "$folder"
        done
    } | sort -u
}

# Move one student's work into $archive_dir, preserving the two-tree layout
# (workspaces/ + claude_config/) so it can simply be moved back to restore.
#
# `mv` is a rename within the same filesystem, which needs write permission
# on the parent directories, not ownership of the contents — so this works
# even though ./workspaces/<user>/.claude is a root-owned Docker mountpoint.
# Returns 0 if anything was moved.
_archive_one_user() {
    local user_name="$1"
    local archive_dir="$2"
    local moved=1

    if [ -d "./workspaces/$user_name" ]; then
        mkdir -p "$archive_dir/workspaces"
        if mv "./workspaces/$user_name" "$archive_dir/workspaces/" 2>/dev/null; then
            moved=0
        else
            echo "⚠ Could not archive ./workspaces/$user_name — left in place."
        fi
    fi

    if [ -d "./claude_config/$user_name" ]; then
        mkdir -p "$archive_dir/claude_config"
        if mv "./claude_config/$user_name" "$archive_dir/claude_config/" 2>/dev/null; then
            moved=0
        else
            echo "⚠ Could not archive ./claude_config/$user_name — left in place."
        fi
    fi

    return $moved
}

# Ask what should happen to student work on disk, then do it.
#
# Usage: prompt_user_data_disposition <mode> <user> [<user> ...]
#   mode "teardown" — whole-lab cleanup. Offers archive / leave / delete.
#   mode "remove"   — a single user being deleted. Offers archive / delete
#                     only: leaving the folder behind would silently bring
#                     the sandbox back, because the compose file is
#                     regenerated from the folders present on disk.
#
# Archive destination is $ARCHIVE_ROOT/<YYYYMMDD-HHMMSS>/ (override
# ARCHIVE_ROOT via .env; defaults to ./archives). One timestamp per run, so
# everything retired together lands in the same folder.
prompt_user_data_disposition() {
    local mode="$1"
    shift
    local users=("$@")
    local archive_root="${ARCHIVE_ROOT:-./archives}"
    local count=${#users[@]}
    local subject answer stamp archive_dir user moved

    if [ "$count" -eq 0 ]; then
        echo "🛈 No student work directories found on disk."
        return 0
    fi

    if [ "$count" -eq 1 ]; then
        subject="the work directory for ${users[0]}"
    else
        subject="the work directories for $count users"
    fi

    echo ""
    echo "What should happen to $subject?"
    echo "  1) Archive — move to $archive_root/<timestamp>/ (kept on disk, next deploy starts clean)"
    if [ "$mode" = "teardown" ]; then
        echo "  2) Leave in place — the next deployment reuses them and students resume their files"
        echo "  3) Delete permanently"
    else
        echo "  2) Delete permanently"
    fi

    while true; do
        if [ "$mode" = "teardown" ]; then
            read -p "Select an option (1-3): " answer
        else
            read -p "Select an option (1-2): " answer
        fi

        # Normalise: in "remove" mode option 2 is delete, which is option 3
        # in "teardown" mode.
        if [ "$mode" != "teardown" ] && [ "$answer" = "2" ]; then
            answer="3"
        elif [ "$mode" != "teardown" ] && [ "$answer" = "3" ]; then
            answer="invalid"
        fi

        case "$answer" in
            1)
                stamp=$(date +%Y%m%d-%H%M%S)
                archive_dir="$archive_root/$stamp"
                moved=0
                for user in "${users[@]}"; do
                    if _archive_one_user "$user" "$archive_dir"; then
                        moved=$((moved + 1))
                        echo "  archived $user"
                    fi
                done
                if [ "$moved" -gt 0 ]; then
                    echo "✔ Archived $moved user folder(s) to $archive_dir"
                else
                    echo "🛈 Nothing was archived."
                fi
                return 0
                ;;
            2)
                echo "🛈 Work directories left in place under ./workspaces and ./claude_config."
                return 0
                ;;
            3)
                echo "Purging host workspace directories..."
                for user in "${users[@]}"; do
                    rm -rf "./workspaces/${user:?}"
                    rm -rf "./claude_config/${user:?}"
                done
                echo "✔ Work directories permanently deleted."
                return 0
                ;;
            *)
                if [ "$mode" = "teardown" ]; then
                    echo "❌ Error: Please enter 1, 2, or 3."
                else
                    echo "❌ Error: Please enter 1 or 2."
                fi
                ;;
        esac
    done
}

# Rebuild $DYNAMIC_COMPOSE from scratch based on whichever
# ./workspaces/<USER_PREFIX>* folders currently exist on disk. Callers must
# set DYNAMIC_COMPOSE, USER_PREFIX, and the vars _emit_service_block needs
# before calling this.
rebuild_dynamic_compose() {
    : > "$DYNAMIC_COMPOSE"
    cat >> "$DYNAMIC_COMPOSE" <<EOF
networks:
  guac_lab_net:
    external: true

services:
EOF

    local folder num user_name
    for folder in ./workspaces/"${USER_PREFIX}"*; do
        [ -d "$folder" ] || continue
        num=$(basename "$folder" | sed "s/^${USER_PREFIX}//")
        user_name="${USER_PREFIX}${num}"
        _emit_service_block "$user_name" >> "$DYNAMIC_COMPOSE"
    done

    echo "volumes:" >> "$DYNAMIC_COMPOSE"
    for folder in ./workspaces/"${USER_PREFIX}"*; do
        [ -d "$folder" ] || continue
        num=$(basename "$folder" | sed "s/^${USER_PREFIX}//")
        echo "  claude_config_${USER_PREFIX}${num}:" >> "$DYNAMIC_COMPOSE"
    done
}
