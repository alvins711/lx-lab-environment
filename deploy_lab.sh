#!/bin/bash

# 1. Automatically detect the machine's primary local IP address
# Works reliably on Debian, Ubuntu, AlmaLinux, RHEL, and Raspberry Pi OS
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')

# Fallback mechanism if the route command fails (e.g. no internet route)
if [ -z "$DETECTED_IP" ]; then
    DETECTED_IP=$(hostname -I | awk '{print $1}')
fi

echo "=================================================="
echo " Detected Machine Local IP: $DETECTED_IP"
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

# Resource constraint variables
CPU_LIMIT="0.5"       
MEM_LIMIT="512m"      

# Ensure host directory structures exist safely
mkdir -p "./config/guacamole"

# Ensure the shared Docker network exists before booting containers
if ! docker network ls | grep -q "guac_lab_net"; then
    echo "Creating external Docker network: guac_lab_net..."
    docker network create guac_lab_net
fi

# 2. Initialize dynamic compose file layout
cat << EOF > $DYNAMIC_COMPOSE

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

echo "Generating access keys and environment spaces..."

# 4. Build unique profiles per student sandbox
for i in $(seq -f "%02g" 1 $USER_COUNT); do
    USER_NAME="user$i"
    USER_PASS="Boomi$i" 
    
    # Provision workspace folders with full host read/write permissions
    mkdir -p "./workspaces/$USER_NAME"
    chmod -R 777 "./workspaces/$USER_NAME"

    # Provision local-disk directory for persistent .claude config
    mkdir -p "./claude_config/$USER_NAME"
    chmod -R 777 "./claude_config/$USER_NAME"

    # Append user service definition block using a Named Volume for .claude config
    cat << EOF >> $DYNAMIC_COMPOSE
  workstation_$USER_NAME:
    build:
      context: .
      dockerfile: Dockerfile.lab
    container_name: workstation_$USER_NAME
    hostname: workstation_$USER_NAME
    environment:
      - CLAUDE_CONFIG_DIR=/home/labuser/.claude
    volumes:
      - ./workspaces/$USER_NAME:/workspace
      - ./claude_config/$USER_NAME:/home/labuser/.claude  # <-- Named volume here
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
        <connection name="Workstation Sandbox ($USER_NAME)">
            <protocol>ssh</protocol>
            <param name="hostname">workstation_$USER_NAME</param>
            <param name="port">22</param>
            <param name="username">labuser</param>
            <param name="password">password123</param>
        </connection>
    </authorize>

EOF
done

# Append the global volume declarations to the end of the dynamic compose file
cat << EOF >> $DYNAMIC_COMPOSE

volumes:
$(for i in $(seq -f "%02g" 1 $USER_COUNT); do echo "  claude_config_user$i:"; done)
EOF

# Close the XML structure properly
echo "</user-mapping>" >> $GUAC_MAPPING

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
