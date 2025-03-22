#!/bin/bash

# Usage: ./webdav.sh <file1/dir1> [file2/dir2 ...]
# Config file (webdav.conf) settings:
# WEBDAV_URL: WebDAV server URL
# USERNAME: WebDAV username
# PASSWORD: WebDAV password
# IGNORE_SSL: Set to 'true' to ignore SSL certificate verification

# Check if curl is installed 
if ! command -v curl &> /dev/null; then
    echo "Error: curl is required but not installed."
    echo "sudo apt update"
    echo "sudo apt install curl"
    echo "curl --version"
    exit 1
fi

CONFIG_FILE="webdav.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    cat > "${CONFIG_FILE}" << EOL
WEBDAV_URL='https://webdav.example.com/remote/path/'
IGNORE_SSL='false'
USERNAME='your_username'
PASSWORD='your_password'
EOL
    echo "Error: Config file not found at $CONFIG_FILE"
    echo "A config file has been created at ${CONFIG_FILE}"
    echo "Please edit it e.g.: vi ${CONFIG_FILE}"
    echo "Update the credentials and webdav location"
    exit 1
fi

# Check if config still has default values
if grep -q "webdav.example.com\|your_username\|your_password" "$CONFIG_FILE"; then
    echo "Error: Config file still contains default values"
    echo -e "\e[31mPlease edit it e.g.: vi ${CONFIG_FILE}\e[0m"
    echo "Update the credentials and webdav location"
    exit 1
fi

source "$CONFIG_FILE"

# Validate required config variables
if [ -z "$WEBDAV_URL" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Error: WEBDAV_URL, USERNAME, and PASSWORD must be set in $CONFIG_FILE"
    exit 1
fi

# Set SSL verification options
CURL_SSL_OPTS=""
if [ "$IGNORE_SSL" = "true" ]; then
    CURL_SSL_OPTS="--insecure"
fi

# Create log directory and file
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/webdav_$(date +%Y%m%d_%H%M%S).log"

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] ${level}: ${message}" >> "$LOG_FILE"
    
    # Also print error messages to stderr
    if [ "$level" = "ERROR" ]; then
        echo "[${timestamp}] ${level}: ${message}" >&2
    fi
}

# Function to check if file exists
check_file_exists() {
    local target="${WEBDAV_URL}${1}"
    
    if curl -u "$USERNAME:$PASSWORD" \
         -s \
         -I \
         $CURL_SSL_OPTS \
         "$target" | grep -q "^HTTP.*200"; then
        return 0
    else
        return 1
    fi
}

# Function to check if directory exists
check_directory_exists() {
    local target="${WEBDAV_URL}${1}"
    
    if curl -u "$USERNAME:$PASSWORD" \
         -s \
         -X PROPFIND \
         $CURL_SSL_OPTS \
         "$target" | grep -q "200\|207"; then
        return 0
    else
        return 1
    fi
}

# Function to URL encode a string
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Function to upload a file
upload_file() {
    local source="$1"
    local target_path="$2"
    local encoded_target_path=$(urlencode "$target_path")
    local target="${WEBDAV_URL}${encoded_target_path}"
    
    log "DEBUG" "Uploading file to URL: $target"
    
    if check_file_exists "$encoded_target_path"; then
        log "INFO" "File already exists, skipping: $encoded_target_path"
        return 0
    fi
    
    if curl -u "$USERNAME:$PASSWORD" \
         -T "$source" \
         $CURL_SSL_OPTS \
         --url "$target"; then
        log "INFO" "Successfully uploaded: $source to $target"
    else
        log "ERROR" "Failed to upload: $source to $target (Exit code: $?)"
    fi
}

# Function to create remote directory
create_directory() {
    local target_path="$1"
    
    if check_directory_exists "$target_path"; then
        log "INFO" "Directory already exists: $target_path"
        return 0
    fi
    
    local target="${WEBDAV_URL}${target_path}"
    
    if curl -u "$USERNAME:$PASSWORD" \
         -X MKCOL \
         -f \
         $CURL_SSL_OPTS \
         "$target"; then
        log "INFO" "Created directory: $target"
        return 0
    else
        log "ERROR" "Failed to create directory: $target (Exit code: $?)"
        return 1
    fi
}

# Function to recursively create directory path
create_directory_recursive() {
    local path="$1"
    local current=""
    declare -A dir_cache
    
    # Split path and create each level
    for dir in ${path//\// }; do
        current="${current}${dir}/"
        
        # Skip if directory exists in cache
        if [[ -n "${dir_cache[$current]}" ]]; then
            log "INFO" "Directory exists (cached): $current"
            continue
        fi
        
        # Skip if directory exists
        if check_directory_exists "$current"; then
            log "INFO" "Directory exists: $current"
            dir_cache["$current"]=1
            continue
        fi
        
        # Try to create directory
        if ! create_directory "$current"; then
            log "ERROR" "Failed to create directory level: $current"
            return 1
        fi
        
        # Add to cache
        dir_cache["$current"]=1
        
        # Small delay to avoid race conditions
        sleep 0.5
    done
    
    return 0
}

# Function to handle directory upload
upload_directory() {
    local source="$1"
    local target="$2"
    declare -A dir_cache
    
    # Create complete directory path
    if ! create_directory_recursive "$target"; then
        log "ERROR" "Failed to create directory structure: $target"
        return 1
    fi
    
    # Upload all files and subdirectories
    find "$source" -type f -print0 | while IFS= read -r -d '' file; do
        # Remove the full source path including the directory name
        local relative_path="${file#$source}"
        # Remove leading slash if present
        relative_path="${relative_path#/}"
        local dir_path=$(dirname "$relative_path")
        
        # Create parent directories if needed
        if [ "$dir_path" != "." ]; then
            if [[ -z "${dir_cache[$target/$dir_path]}" ]]; then
                create_directory "$target/$dir_path"
                dir_cache["$target/$dir_path"]=1
            fi
        fi
        
        upload_file "$file" "$target/$relative_path"
    done
}

# Process each argument
for SOURCE in "$@"; do
    if [ -f "$SOURCE" ]; then
        filename=$(basename "$SOURCE")
        if ! upload_file "$SOURCE" "$filename"; then
            log "ERROR" "Failed processing file: $SOURCE"
        fi
    elif [ -d "$SOURCE" ]; then
        dirname=$(basename "$SOURCE")
        if ! upload_directory "$SOURCE" "$dirname"; then
            log "ERROR" "Failed processing directory: $SOURCE"
        fi
    else
        log "ERROR" "File/directory does not exist: $SOURCE"
    fi
done

log "INFO" "Upload script completed"