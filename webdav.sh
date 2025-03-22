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

# Function to upload a file
upload_file() {
    local source="$1"
    local target="${WEBDAV_URL}${2}"
    
    echo "Uploading: $source -> $target"
    
    curl -u "$USERNAME:$PASSWORD" \
         --upload-file "$source" \
         -f \
         $CURL_SSL_OPTS \
         "$target"
    
    return $?
}

# Function to create remote directory
create_directory() {
    local target="${WEBDAV_URL}${1}"
    
    curl -u "$USERNAME:$PASSWORD" \
         -X MKCOL \
         -f \
         $CURL_SSL_OPTS \
         "$target"
    
    return $?
}

# Function to handle directory upload
upload_directory() {
    local source="$1"
    local target="$2"
    
    # Create remote directory
    create_directory "$target"
    
    # Upload all files and subdirectories
    find "$source" -type f -print0 | while IFS= read -r -d '' file; do
        local relative_path="${file#$source/}"
        local dir_path=$(dirname "$relative_path")
        
        # Create parent directories if needed
        if [ "$dir_path" != "." ]; then
            create_directory "$target/$dir_path"
        fi
        
        upload_file "$file" "$target/$relative_path"
    done
}

# Process each argument
for SOURCE in "$@"; do
    if [ -f "$SOURCE" ]; then
        # Upload single file
        filename=$(basename "$SOURCE")
        upload_file "$SOURCE" "$filename"
    elif [ -d "$SOURCE" ]; then
        # Upload directory
        dirname=$(basename "$SOURCE")
        upload_directory "$SOURCE" "$dirname"
    else
        echo "Warning: '$SOURCE' does not exist, skipping..."
    fi
done