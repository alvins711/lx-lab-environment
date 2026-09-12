# Zero-Config Multi-User Claude Code Lab Environment

This guide provides everything you need to deploy an isolated, multi-user **Claude Code** lab on **any Linux machine**. 

The environment automatically detects the host's network IP address at runtime, configuring **Caddy** as the reverse proxy and **Apache Guacamole** as the clientless, browser-based terminal interface. Every student gets a resource-constrained, private container sandbox.

---

## 📂 1. Project Directory Layout

Create a deployment directory on your target host system and switch to it:

```bash
mkdir -p ~/claude_lab
cd ~/claude_lab
```

Your final working directory must contain these five files:
```text
~/claude_lab/
├── Caddyfile
├── Dockerfile.lab
├── cleanup_lab.sh
├── deploy_lab.sh
└── docker-compose.yml
```

---

## 🛠️ 2. Core Infrastructure & Environment Files

Create the following files inside your `~/claude_lab` folder.

### `Dockerfile.lab`
Defines the base Linux image for student environments. It includes Node.js, Git, an SSH daemon, and pre-caches the Claude Code CLI tool.

```dockerfile
FROM node:lts-bookworm-slim

# Install SSH server, Git, and system dependencies
RUN apt-get update && apt-get install -y \
    openssh-server \
    git \
    sudo \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Configure the SSH daemon runtime directory
RUN mkdir /var/run/sshd

# Create a standard, non-root lab user
RUN useradd -rm -d /home/labuser -s /bin/bash -g root -G sudo -u 1001 labuser
# Set a default container-level password
RUN echo 'labuser:password123' | chpasswd

# Install Claude Code globally so it is pre-cached for users
RUN npm install -g @anthropic-ai/claude-code

# Set up the workspace mounting target
WORKDIR /workspace
RUN chown -R labuser:root /workspace

EXPOSE 22

# Start the SSH daemon on container initialization
CMD ["/usr/sbin/sshd", "-D"]
```

### `docker-compose.yml`
Defines the core, persistent gateway services. Caddy dynamically consumes the detected host IP address using the environment variable string passed by the execution layer.

```yaml
version: '3.8'

networks:
  guac_lab_net:
    name: guac_lab_net
    driver: bridge

services:
  caddy:
    image: caddy:latest
    container_name: caddy_proxy
    ports:
      - "80:80"
      - "443:443"
    environment:
      - HOST_IP=${HOST_IP}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - guac_lab_net
    restart: unless-stopped

  guacamole:
    image: guacamole/guacamole:latest
    container_name: guacamole_web
    environment:
      - GUACD_HOSTNAME=guacd
    volumes:
      - ./config/guacamole/user-mapping.xml:/etc/guacamole/user-mapping.xml
    networks:
      - guac_lab_net
    restart: unless-stopped

  guacd:
    image: guacamole/guacd:latest
    container_name: guacamole_daemon
    networks:
      - guac_lab_net
    restart: unless-stopped

volumes:
  caddy_data:
  caddy_config:
```

### `Caddyfile`
Proxies web and WebSocket traffic straight to Guacamole. It automatically interpolates the runtime environment variable payload sent down from the host.

```caddy
{$HOST_IP:http://} {
    # Reverse proxy to the Guacamole web app container
    reverse_proxy guacamole:8080 {
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    
    # Clean redirect from the root index straight to the login interface
    redir / /guacamole/ 308
}
```

---

## 🚀 3. Lifecycle Automation Scripts

### `deploy_lab.sh`
Queries the core routing table to isolate the machine's true host network adapter IP. It configures explicit CPU/RAM locks per student sandbox to protect system infrastructure.

```bash
#!/bin/bash

# 1. Automatically detect the machine's primary local IP address
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')

# Fallback mechanism if the route command fails
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP=$(hostname -I | awk '{print $1}')
fi

echo "=================================================="
echo " Detected Host Machine Local IP: $DETECTED_IP"
echo "=================================================="
export HOST_IP="$DETECTED_IP"

# Prompt for the number of user sandboxes needed
read -p "Enter the number of student sandboxes to deploy: " USER_COUNT

# Validate user input is a positive integer
if ! [[ "$USER_COUNT" =~ ^[0-9]+$ ]] ; then
   echo "Error: Input must be a valid number."
   exit 1
fi

DYNAMIC_COMPOSE="docker-compose.users.yml"
GUAC_MAPPING="./config/guacamole/user-mapping.xml"

# Strict resource constraint boundaries per user container
CPU_LIMIT="0.5"       # Restricts each student to 50% of a single CPU core
MEM_LIMIT="512m"      # Hard ceiling cap of 512MB RAM per sandbox

# Ensure host directory structures exist safely
mkdir -p "./config/guacamole"

# 2. Initialize dynamic compose file layout
cat << EOF > $DYNAMIC_COMPOSE
version: '3.8'

networks:
  guac_lab_net:
    external: true

services:
EOF

# 3. Initialize the user-mapping.xml file layout
cat << EOF > $GUAC_MAPPING
<user-mapping>
    <!-- Default Infrastructure Administrator Account -->
    <authorize username="guacadmin" password="password123">
    </authorize>

EOF

echo "Generating workspaces and provisioning hardware limits..."

# 4. Build unique profiles per student sandbox
for i in $(seq -f "%02g" 1 $USER_COUNT); do
    USER_NAME="user$i"
    USER_PASS="PassClaude$i"
    
    # Provision workspace folders with full host read/write permissions
    mkdir -p "./workspaces/$USER_NAME"
    mkdir -p "./config/user_profiles/$USER_NAME"
    chmod -R 777 "./workspaces/$USER_NAME" "./config/user_profiles/$USER_NAME"

    # Append user service definition block with explicit CPU/Memory limits
    cat << EOF >> $DYNAMIC_COMPOSE
  claude_ssh_$USER_NAME:
    build:
      context: .
      dockerfile: Dockerfile.lab
    container_name: claude_ssh_$USER_NAME
    environment:
      - CLAUDE_CONFIG_DIR=/home/labuser/.claude
    volumes:
      - ./workspaces/$USER_NAME:/workspace
      - ./config/user_profiles/$USER_NAME:/home/labuser/.claude
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT}'
          memory: ${MEM_LIMIT}
    networks:
      - guac_lab_net
    restart: unless-stopped

EOF

    # Map the unique user account straight into Guacamole via internal container DNS
    cat << EOF >> $GUAC_MAPPING
    <!-- Access Profile for $USER_NAME -->
    <authorize username="$USER_NAME" password="$USER_PASS">
        <connection name="Claude Sandbox ($USER_NAME)">
            <protocol>ssh</protocol>
            <param name="hostname">claude_ssh_$USER_NAME</param>
            <param name="port">22</param>
            <param name="username">labuser</param>
            <param name="password">password123</param>
        </connection>
    </authorize>

EOF
done

# Close the XML structure properly
echo "</user-mapping>" >> $GUAC_MAPPING

echo "✔ Generated $USER_COUNT configurations in $DYNAMIC_COMPOSE"
echo "✔ Updated web terminal maps in $GUAC_MAPPING"
echo "Initializing the environment stack..."

# Run both files concurrently, passing the exported environment variables safely
docker compose -f docker-compose.yml -f docker-compose.users.yml up -d --build

echo ""
echo "=================================================="
echo " Lab is live! Direct your students to open:"
echo " http://$DETECTED_IP/guacamole/"
echo "=================================================="
```

### `cleanup_lab.sh`
Gracefully drops running student instances, purges transient user entries from the authorization manifest, and provides options to scrub code workspaces.

```bash
#!/bin/bash

DYNAMIC_COMPOSE="docker-compose.users.yml"
GUAC_MAPPING="./config/guacamole/user-mapping.xml"

echo "=== Claude Code Lab Stack Teardown ==="

# Exit if no dynamic user deployment layout is found
if [ ! -f "$DYNAMIC_COMPOSE" ]; then
    echo "⚠ Active configuration layout ($DYNAMIC_COMPOSE) not found."
    exit 0
fi

echo "Spinning down running user sandboxes..."
docker compose -f docker-compose.yml -f docker-compose.users.yml down --remove-orphans

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
read -p "Do you want to permanently delete all student files and Claude tokens? (y/N): " PURGE_DATA

if [[ "$PURGE_DATA" =~ ^[Yy]$ ]]; then
    echo "Purging data directories..."
    rm -rf ./workspaces/user*
    rm -rf ./config/user_profiles/user*
    echo "✔ Workspaces and state logs completely scrubbed."
else
    echo "🛈 Workspace folder contents preserved inside ./workspaces."
fi

echo "=== Environment Sanitized ==="
```

---

## 📈 4. Operations & Lifecycle Management

### Step 1: Initialize script rights
Before driving execution parameters on a new system host, assign execute flags to the helper suite:
```bash
chmod +x deploy_lab.sh cleanup_lab.sh
```

### Step 2: Spin up the dynamic cluster
Fire up the deployment manager tool:
```bash
./deploy_lab.sh
```
