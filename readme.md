# Zero-Config Multi-User Claude Code Lab Environment (HTTPS)

This repository contains an automated framework designed to spin up an isolated, multi-user **Claude Code** lab on **any Linux host**. 

The architecture automatically detects the machine's host LAN IP address at runtime, configuring **Caddy** to use its internal Certificate Authority (CA) for local **HTTPS encryption**, and **Apache Guacamole** as the secure, clientless browser-to-terminal interface. Every student receives a hardware-constrained, private container sandbox with persistent development toolchains pre-cached.

---

## System Architecture

```text
[ Internet ] -> HTTPS -> [ Caddy Proxy ] -> HTTP (Port 8080) -> [ Apache Guacamole ]-> SSH (Port 22) -> [ Isolated Student Containers ]
																										├── Hostname: userXX
																										├── RAM Cap: 512MB
																										└── CPU Cap: 50% Core
```
---

## Project Repository Tree

Ensure your project space mimics the layout below before execution:

```text
~/lx-lab-environment/
├── .env
├── .gitignore
├── Caddyfile
├── cleanup_lab.sh
├── custom_bashrc.tmpl
├── custom_profile.tmpl
├── deploy_lab.sh
├── docker-compose.yml
├── Dockerfile.lab
├── manage_users.sh
└── readme.md
```

---

## Configuring the `.env` File

All runtime configuration is read from a `.env` file in the project root. Both `deploy_lab.sh` and `cleanup_lab.sh` source it automatically, so you only need to create it **once** before your first deployment.

> **Note:** `.env` is listed in `.gitignore` and is **not** committed to the repository. Create it locally on each host.

### Creating the file

Copy the template below into a new file named `.env` in the project root (`~/lx-lab-environment/.env`):

```bash
# Lab Workstation Resource Limits (per sandbox)
CPU_LIMIT=0.5
MEM_LIMIT=512m

# User Credential Configuration
USER_PREFIX=user
PASS_PREFIX=user

# Guacamole / SSH settings
SSH_PASSWORD=password123
ADMIN_PASSWORD=password123

# Claude endpoint configuration (REQUIRED)
ANTHROPIC_BASE_URL=http://localhost:11434
ANTHROPIC_API_KEY=your-api-key
ANTHROPIC_AUTH_TOKEN=your-auth-token
ANTHROPIC_MODEL=your/model-name:tag
```

### Variable reference

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `CPU_LIMIT` | No | `0.5` | CPU cores allocated to each sandbox (e.g. `0.5` = half a core). |
| `MEM_LIMIT` | No | `512m` | Memory cap per sandbox (e.g. `512m`, `1g`). |
| `USER_PREFIX` | No | `user` | Prefix for student usernames (`user01`, `user02`...). |
| `PASS_PREFIX` | No | `user` | Prefix for student passwords (`user01`, `user02`...). |
| `SSH_PASSWORD` | No | `password123` | Password for the `labuser` account inside each sandbox. |
| `ADMIN_PASSWORD` | No | `password123` | Password for the `guacadmin` Guacamole account. |
| `ANTHROPIC_BASE_URL` | **Yes** | — | Base URL of the LLM endpoint (e.g. an Ollama or Anthropic-compatible server). |
| `ANTHROPIC_API_KEY` | **Yes** | — | API key sent to the endpoint (e.g. `your-api-key`). |
| `ANTHROPIC_AUTH_TOKEN` | **Yes** | — | Auth token sent to the endpoint (e.g. `your-auth-token`). |
| `ANTHROPIC_MODEL` | **Yes** | — | Model identifier to use (e.g. `your/model-name:tag`). |

### How the AI variables are applied

The four `ANTHROPIC_*` values are passed to the container as **Docker build args** and baked into `/etc/environment`. This makes them available in every SSH login shell (visible via `printenv`), not just the container's entrypoint process. If any of the four are missing, `deploy_lab.sh` exits with a clear error before building.

---

## Step-by-Step Instructions

### Step 1: Initialize Script Permissions
Open your terminal on the host machine inside your project folder (`~/lx-lab-environment`) and grant execution rights to your control scripts:
```bash
chmod +x deploy_lab.sh cleanup_lab.sh manage_users.sh
```

Optionally, edit the `.env` file to modify usernames, passwords, resource limits, and the AI endpoint (see [Configuring the `.env` File](#configuring-the-env-file) below). The `ANTHROPIC_*` variables are **required** — the deploy script will fail fast if any are missing.

### Step 2: Launch the Lab Environment
Run the deployment automation script:
```bash
./deploy_lab.sh
```
When prompted, enter the **number of student sandboxes** you wish to deploy (e.g., `10`). The script will automatically:
1. Detect your local network IP address.
2. Create the shared Docker network (`guac_lab_net`) if it does not exist.
3. Build the student containers (`user01`, `user02`...) with `vim`, `nano`, and Claude Code pre-cached.
4. Generate the Apache Guacamole authentication mapping file.
5. Launch the entire proxy and sandbox stack.

### Step 3: Access and Test the Platform
Once the script finishes, it will print a secure live link: `https://<DETECTED_IP>/guacamole/`.

1. Open an **Incognito / Private browser window** on any device connected to your local network.
2. Navigate to the `https://` URL provided by the script.
3. Bypass the local self-signed SSL warning by clicking **Advanced** ➔ **Proceed to IP (unsafe)**.
4. Log in using a student credential pair generated by the script:
   * **Username:** `user01` (or `user02`, `user03`...)
   * **Password:** `Boomi01` (or `Boomi02`, `Boomi03`...)
5. Once inside the browser terminal, type `claude` to start the AI agent, or use `vim` / `nano` for editing files.
6. (Optional) Admin login: Username `guacadmin`, Password `password123`.

### Management
After deployment you can view, add, remove users using the management script
```bash
./manage_users.sh
```
### Step 4: Tear Down and Clean Up
When your classroom session or testing period ends, clean up the running containers and destroy the configuration volumes to wipe student tokens:
```bash
./cleanup_lab.sh
```
The script will ask if you want to permanently delete student workspace files from the host disk or preserve them for the next session.



### Pre-setup & Troubleshooting: 
When deploying on Windows, a few thing to consider:

1. Install Docker on WSL instead of Hyper V
2. Enable Docker host networking  
	> Settings-\>Resources-\>Network-\>Enable host networking
3. Configure WSL to mirrored networking mode - edit %USERPROFILE%\.wslconfig 
	> [wsl2] networkingMode=mirrored
4. Add firewall rule - Powershell  
	> New-NetFirewallRule -DisplayName "Open HTTPS Port 443" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow


