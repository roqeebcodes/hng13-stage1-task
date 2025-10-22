

#!/bin/bash

set -e # Stops immediately if any command fails
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Define a simple logging function
log_action() {
    local MESSAGE=$1
    local STATUS=${2:-SUCCESS}
    echo "$(date +'%H:%M:%S') [${STATUS}] - ${MESSAGE}" | tee -a "${LOG_FILE}"
    if [ "${STATUS}" == "ERROR" ]; then
        exit 1
    fi
}

# Define a cleanup function (runs at the end or on error)
    
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Define a simple logging function
log_action() {
    local MESSAGE=$1
    local STATUS=${2:-SUCCESS}
    echo "$(date +'%H:%M:%S') [${STATUS}] - ${MESSAGE}" | tee -a "${LOG_FILE}"
    if [ "${STATUS}" == "ERROR" ]; then
        exit 1
    fi
}

# Define a cleanup function (runs at the end or on error)
cleanup_and_exit() {
    log_action "Script finished or encountered an error." "INFO"
    exit $?
}

# Define a simple logging function
log_action() {
    local MESSAGE=$1
    local STATUS=${2:-SUCCESS}
    echo "$(date +'%H:%M:%S') [${STATUS}] - ${MESSAGE}" | tee -a "${LOG_FILE}"
    if [ "${STATUS}" == "ERROR" ]; then
        exit 1
    fi
}

# Define a cleanup function (runs at the end or on error)
cleanup_and_exit() {
    log_action "Script finished or encountered an error." "INFO"
    exit $?
}
trap cleanup_and_exit EXIT

get_user_input() {
    log_action "Collecting deployment parameters..."
    
    # 🚨 Use a simple public Docker repo URL here for testing
    read -p "Git Repository URL (e.g., https://.../my-app.git): " REPO_URL
    read -s -p "Personal Access Token (PAT): " PAT
    echo
    
    # Use the details from your Stage 0 server
    read -p "Remote Server IP: " SSH_IP
    read -p "SSH Username: " SSH_USER
    read -p "SSH Key Path (e.g., ~/.ssh/id_rsa): " SSH_KEY
    
    # Common internal container ports are 8080 or 3000
    read -p "Container Internal Port (e.g., 8080): " APP_PORT
}

handle_local_repo() {
    # Extract app folder name from the URL
    PROJECT_DIR=$(basename "$REPO_URL" .git)
    GIT_AUTH_URL="https://${PAT}@${REPO_URL#https://}"

    if [ -d "$PROJECT_DIR" ]; then
        log_action "Pulling latest code."
        cd "$PROJECT_DIR" && git pull || log_action "Git pull failed." "ERROR"
    else
        log_action "Cloning repository."
        git clone "$GIT_AUTH_URL"
        cd "$PROJECT_DIR" || log_action "Failed to CD." "ERROR"
    fi

    # CRITICAL: Transfer the code to the remote server
    log_action "Transferring project files via SCP..."
    scp -r -i "${SSH_KEY}" ./* "${SSH_USER}"@"${SSH_IP}":/home/"${SSH_USER}"/"${PROJECT_DIR}" || log_action "SCP failed." "ERROR"
}


remote_deploy_and_configure() {
    log_action "Starting remote setup and deployment on ${SSH_IP}..."

    # 1. Define the NGINX configuration (to run on the server)
    NGINX_CONF=$(cat <<EOF
server {
    listen 80;
    server_name ${SSH_IP};
    location / {
        # FORWARD traffic to the Docker container's internal port
        proxy_pass http://127.0.0.1:${APP_PORT};
        # ... standard proxy headers ...
    }
}
EOF
)

    # 2. Define the entire remote script to be executed
    REMOTE_SCRIPT=$(cat <<EOF
        # --- Preparation ---
        sudo apt update -y
        sudo apt install -y docker.io docker-compose nginx

        # --- Docker Deployment (Idempotent) ---
        cd /home/${SSH_USER}/${PROJECT_DIR}

	# Stop and remove the single-container deployment by its exact name
        sudo docker rm -f my-app-container 2>/dev/null || true
	        
        # Stop and remove old containers to prevent port conflicts
        sudo docker-compose down 2>/dev/null || sudo docker rm -f \$(sudo docker ps -aq --filter ancestor=my-app) 2>/dev/null || true
        
        # Build and Run the application
        if [ -f docker-compose.yml ]; then
            sudo docker-compose up -d --build
        else
            sudo docker build -t my-app .
            sudo docker run -d -p ${APP_PORT}:${APP_PORT} --name my-app-container my-app
        fi

	sleep 5
        # --- NGINX Configuration ---
        # Overwrite the default config with the dynamic proxy config
        echo "${NGINX_CONF}" | sudo tee /etc/nginx/sites-available/default > /dev/null
        
        # Test config and reload service
        sudo nginx -t && sudo systemctl reload nginx || exit 1
EOF
)
    # Execute the script remotely
    ssh -i "${SSH_KEY}" "${SSH_USER}"@"${SSH_IP}" "${REMOTE_SCRIPT}" || log_action "Remote script execution failed." "ERROR"
}


main() {
    get_user_input
    handle_local_repo
    remote_deploy_and_configure
    
    # Final Validation Check: Check Port 80 access
    log_action "Running final external validation..."
     HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" "http://${SSH_IP}")
    if [ "$HTTP_CODE" == "200" ]; then
        log_action "Deployment SUCCESSFUL! Application live on http://${SSH_IP}"
    else
        log_action "Validation FAILED. HTTP Code: $HTTP_CODE" "ERROR"
    fi
}

# Run the main function
main
