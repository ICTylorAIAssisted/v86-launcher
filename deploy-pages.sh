#!/bin/bash
#
# Deploy static site to Cloudflare Pages
#
# Prerequisites:
#   - Cloudflare account
#   - API token with Pages permissions (Account > Cloudflare Pages: Edit)
#   - jq installed (for JSON parsing)
#   - sha256sum or shasum (for file hashing)
#
# Usage:
#   ./deploy-pages.sh <zip-file-or-directory> [project-name]
#
# Examples:
#   ./deploy-pages.sh ./dist my-site
#   ./deploy-pages.sh site.zip v86-interview
#   ./deploy-pages.sh . my-project
#
# Environment variables (or will prompt):
#   CF_API_TOKEN    - Cloudflare API token
#   CF_ACCOUNT_ID   - Cloudflare account ID
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check dependencies
for cmd in jq curl; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd is required but not installed.${NC}"
        exit 1
    fi
done

# Find sha256 command
if command -v sha256sum &> /dev/null; then
    SHA256_CMD="sha256sum"
elif command -v shasum &> /dev/null; then
    SHA256_CMD="shasum -a 256"
else
    echo -e "${RED}Error: sha256sum or shasum is required but not installed.${NC}"
    exit 1
fi

# Parse arguments
SOURCE="${1:-.}"
PROJECT_NAME="${2:-}"

if [ ! -e "$SOURCE" ]; then
    echo -e "${RED}Error: Source '$SOURCE' not found${NC}"
    echo ""
    echo "Usage: $0 <zip-file-or-directory> [project-name]"
    exit 1
fi

echo -e "${GREEN}=== Cloudflare Pages Deployment ===${NC}\n"

# Get credentials
if [ -z "$CF_API_TOKEN" ]; then
    echo -e "${YELLOW}Cloudflare API Token not set.${NC}"
    echo "Create one at: https://dash.cloudflare.com/profile/api-tokens"
    echo "Required permissions: Account > Cloudflare Pages: Edit"
    echo ""
    read -p "Enter API Token: " CF_API_TOKEN
fi

if [ -z "$CF_ACCOUNT_ID" ]; then
    echo -e "${YELLOW}Cloudflare Account ID not set.${NC}"
    echo "Find it at: https://dash.cloudflare.com → Workers & Pages → Overview (right sidebar)"
    echo ""
    read -p "Enter Account ID: " CF_ACCOUNT_ID
fi

if [ -z "$PROJECT_NAME" ]; then
    # Generate from directory name or default
    if [ -d "$SOURCE" ]; then
        PROJECT_NAME=$(basename "$(cd "$SOURCE" && pwd)")
    else
        PROJECT_NAME=$(basename "$SOURCE" .zip)
    fi
    # Sanitize: lowercase, replace spaces/underscores with hyphens
    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
    
    echo -e "${YELLOW}No project name specified, using: ${PROJECT_NAME}${NC}"
    read -p "Press Enter to confirm or type a different name: " CUSTOM_NAME
    if [ -n "$CUSTOM_NAME" ]; then
        PROJECT_NAME="$CUSTOM_NAME"
    fi
fi

API_BASE="https://api.cloudflare.com/client/v4"

# Helper function to check API response
check_success() {
    local response=$1
    local error_msg=$2
    
    if ! echo "$response" | jq -e '.success == true' > /dev/null 2>&1; then
        echo -e "${RED}$error_msg${NC}"
        echo "$response" | jq .
        exit 1
    fi
}

# Verify token
echo "Verifying API token..."
VERIFY=$(curl -s -X GET "$API_BASE/user/tokens/verify" \
    -H "Authorization: Bearer $CF_API_TOKEN")
check_success "$VERIFY" "Invalid API token"
echo -e "${GREEN}✓ Token valid${NC}\n"

# Prepare files
echo "Preparing files..."
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

if [ -f "$SOURCE" ] && [[ "$SOURCE" == *.zip ]]; then
    # Unzip to temp directory
    echo "  Extracting zip file..."
    unzip -q "$SOURCE" -d "$WORK_DIR/site"
    
    # Check if zip has a single root directory
    CONTENTS=("$WORK_DIR/site"/*)
    if [ ${#CONTENTS[@]} -eq 1 ] && [ -d "${CONTENTS[0]}" ]; then
        # Move contents up one level
        mv "$WORK_DIR/site"/*/* "$WORK_DIR/site/" 2>/dev/null || true
        rmdir "${CONTENTS[0]}" 2>/dev/null || true
    fi
    DEPLOY_DIR="$WORK_DIR/site"
elif [ -d "$SOURCE" ]; then
    DEPLOY_DIR="$SOURCE"
else
    echo -e "${RED}Error: Source must be a directory or .zip file${NC}"
    exit 1
fi

# Count files
FILE_COUNT=$(find "$DEPLOY_DIR" -type f | wc -l | tr -d ' ')
echo -e "${GREEN}✓ Found $FILE_COUNT files to deploy${NC}\n"

if [ "$FILE_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No files found to deploy${NC}"
    exit 1
fi

# Check if project exists
echo "Checking project..."
PROJECT_CHECK=$(curl -s -X GET \
    "$API_BASE/accounts/$CF_ACCOUNT_ID/pages/projects/$PROJECT_NAME" \
    -H "Authorization: Bearer $CF_API_TOKEN")

if echo "$PROJECT_CHECK" | jq -e '.success == true' > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Using existing project: $PROJECT_NAME${NC}"
else
    echo "Creating project: $PROJECT_NAME"
    PROJECT_CREATE=$(curl -s -X POST \
        "$API_BASE/accounts/$CF_ACCOUNT_ID/pages/projects" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$PROJECT_NAME\",\"production_branch\":\"main\"}")
    
    check_success "$PROJECT_CREATE" "Failed to create project"
    echo -e "${GREEN}✓ Created project: $PROJECT_NAME${NC}"
fi
echo ""

# Build file manifest with hashes
echo "Building file manifest..."
MANIFEST_FILE="$WORK_DIR/manifest.json"
HASH_MAP_FILE="$WORK_DIR/hash_map.txt"

echo "{}" > "$MANIFEST_FILE"
> "$HASH_MAP_FILE"

cd "$DEPLOY_DIR"

# Build manifest file directly (more robust than building in variable)
while IFS= read -r -d '' file; do
    REL_PATH="${file#./}"
    # Ensure path starts with /
    if [[ "$REL_PATH" != /* ]]; then
        REL_PATH="/$REL_PATH"
    fi
    
    # Calculate SHA-256 hash
    HASH=$($SHA256_CMD "$file" | cut -d' ' -f1)
    
    # Add to manifest file
    TMP_MANIFEST="$WORK_DIR/manifest_tmp.json"
    jq --arg path "$REL_PATH" --arg hash "$HASH" '. + {($path): $hash}' "$MANIFEST_FILE" > "$TMP_MANIFEST"
    mv "$TMP_MANIFEST" "$MANIFEST_FILE"
    
    # Save hash->file mapping
    echo "$HASH $file" >> "$HASH_MAP_FILE"
    
done < <(find . -type f -print0)

cd - > /dev/null

# Verify manifest is valid JSON
if ! jq -e '.' "$MANIFEST_FILE" > /dev/null 2>&1; then
    echo -e "${RED}Error: Failed to build valid manifest JSON${NC}"
    cat "$MANIFEST_FILE"
    exit 1
fi

FILE_COUNT_MANIFEST=$(jq 'length' "$MANIFEST_FILE")
echo -e "${GREEN}✓ Manifest built with $FILE_COUNT_MANIFEST files${NC}\n"

# Create deployment with manifest using multipart form-data
echo "Creating deployment..."

echo "  Manifest preview:"
jq -c '.' "$MANIFEST_FILE" | head -c 300
echo "..."
echo ""

echo "  Sending request..."

DEPLOY_RESULT=$(curl -s -X POST \
    "$API_BASE/accounts/$CF_ACCOUNT_ID/pages/projects/$PROJECT_NAME/deployments" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -F "manifest=<$MANIFEST_FILE;type=application/json")

if ! echo "$DEPLOY_RESULT" | jq -e '.success == true' > /dev/null 2>&1; then
    echo -e "${RED}Failed to create deployment${NC}"
    echo "$DEPLOY_RESULT" | jq .
    exit 1
fi

DEPLOY_ID=$(echo "$DEPLOY_RESULT" | jq -r '.result.id')
DEPLOY_URL=$(echo "$DEPLOY_RESULT" | jq -r '.result.url // empty')

# Debug: show full deployment response
echo ""
echo "  Deployment response:"
echo "$DEPLOY_RESULT" | jq '{id: .result.id, url: .result.url, missing_hashes_count: (.result.missing_hashes | length), first_5_hashes: (.result.missing_hashes[:5])}'

# Check which files need uploading (missing_hashes)
MISSING_HASHES=$(echo "$DEPLOY_RESULT" | jq -r '.result.missing_hashes // [] | .[]')
MISSING_COUNT=$(echo "$DEPLOY_RESULT" | jq -r '.result.missing_hashes // [] | length')

echo ""
echo -e "${GREEN}✓ Deployment created: $DEPLOY_ID${NC}"
echo "  Files to upload: $MISSING_COUNT"
echo ""

# Upload the missing files
if [ "$MISSING_COUNT" -gt 0 ]; then
    echo "Uploading files..."
    UPLOADED=0
    FAILED=0
    
    cd "$DEPLOY_DIR"
    
    # Upload files one at a time for reliability
    for HASH in $MISSING_HASHES; do
        # Find the file with this hash from the hash map file
        FILE=$(grep "^$HASH " "$HASH_MAP_FILE" | cut -d' ' -f2-)
        
        if [ -z "$FILE" ]; then
            echo -e "${YELLOW}  Warning: No file found for hash $HASH${NC}"
            continue
        fi
        
        REL_PATH="${FILE#./}"
        printf "  Uploading: %s ... " "$REL_PATH"
        
        # Upload single file with hash as field name
        UPLOAD_RESULT=$(curl -s -X POST \
            "$API_BASE/accounts/$CF_ACCOUNT_ID/pages/projects/$PROJECT_NAME/deployments/$DEPLOY_ID/files" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -F "$HASH=@$FILE")
        
        if echo "$UPLOAD_RESULT" | jq -e '.success == true' > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
            UPLOADED=$((UPLOADED + 1))
        else
            echo -e "${RED}✗${NC}"
            echo "    Error: $(echo "$UPLOAD_RESULT" | jq -r '.errors[0].message // "unknown"')"
            FAILED=$((FAILED + 1))
        fi
    done
    
    cd - > /dev/null
    echo ""
    echo -e "${GREEN}✓ Uploaded $UPLOADED files${NC}"
    
    if [ $FAILED -gt 0 ]; then
        echo -e "${YELLOW}  Warning: $FAILED files failed to upload${NC}"
    fi
    echo ""
else
    echo -e "${GREEN}✓ All files already in Cloudflare's cache${NC}"
    echo "  (Files were uploaded in a previous deployment)"
    echo ""
fi

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
MAX_WAIT=120
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS_CHECK=$(curl -s -X GET \
        "$API_BASE/accounts/$CF_ACCOUNT_ID/pages/projects/$PROJECT_NAME/deployments/$DEPLOY_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN")
    
    STAGE=$(echo "$STATUS_CHECK" | jq -r '.result.latest_stage.name // "unknown"')
    STATUS=$(echo "$STATUS_CHECK" | jq -r '.result.latest_stage.status // "unknown"')
    
    if [ "$STATUS" = "success" ] && [ "$STAGE" = "deploy" ]; then
        echo -e "\n${GREEN}✓ Deployment complete${NC}"
        break
    elif [ "$STATUS" = "failure" ]; then
        echo -e "\n${RED}✗ Deployment failed${NC}"
        echo "$STATUS_CHECK" | jq '.result.stages'
        exit 1
    else
        printf "\r  Stage: %-15s Status: %-10s (%ds)" "$STAGE" "$STATUS" "$WAITED"
        sleep 3
        WAITED=$((WAITED + 3))
    fi
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo -e "\n${YELLOW}Timeout waiting for deployment - check dashboard for status${NC}"
fi

# Get final URLs
DEPLOY_URL=$(echo "$STATUS_CHECK" | jq -r '.result.url // empty')
PROJECT_INFO=$(curl -s -X GET \
    "$API_BASE/accounts/$CF_ACCOUNT_ID/pages/projects/$PROJECT_NAME" \
    -H "Authorization: Bearer $CF_API_TOKEN")

PROD_SUBDOMAIN=$(echo "$PROJECT_INFO" | jq -r '.result.subdomain // empty')
CUSTOM_DOMAINS=$(echo "$PROJECT_INFO" | jq -r '.result.domains // [] | join(", ")')

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
if [ -n "$DEPLOY_URL" ]; then
    echo -e "${BLUE}Deployment URL:${NC}  $DEPLOY_URL"
fi
if [ -n "$PROD_SUBDOMAIN" ]; then
    echo -e "${BLUE}Production URL:${NC}  https://$PROD_SUBDOMAIN"
fi
if [ -n "$CUSTOM_DOMAINS" ] && [ "$CUSTOM_DOMAINS" != "" ]; then
    echo -e "${BLUE}Custom domains:${NC}  $CUSTOM_DOMAINS"
fi
echo ""
echo "Project dashboard:"
echo "  https://dash.cloudflare.com/$CF_ACCOUNT_ID/pages/view/$PROJECT_NAME"
echo ""

# Health check
if [ -n "$DEPLOY_URL" ]; then
    echo "Verifying deployment..."
    sleep 3  # Give Cloudflare a moment to propagate
    
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$DEPLOY_URL" 2>/dev/null)
    
    if [ "$HTTP_STATUS" = "200" ]; then
        echo -e "${GREEN}✓ Site is accessible (HTTP $HTTP_STATUS)${NC}"
    elif [ "$HTTP_STATUS" = "000" ]; then
        echo -e "${YELLOW}⚠ Could not connect to site (check manually)${NC}"
    else
        echo -e "${YELLOW}⚠ Site returned HTTP $HTTP_STATUS (may need a few more seconds)${NC}"
        echo "  Try: curl -I $DEPLOY_URL"
    fi
    echo ""
fi

# Save deployment info
cat > .pages-deploy-config <<EOF
PROJECT_NAME=$PROJECT_NAME
DEPLOY_ID=$DEPLOY_ID
DEPLOY_URL=$DEPLOY_URL
PROD_URL=https://$PROD_SUBDOMAIN
CF_ACCOUNT_ID=$CF_ACCOUNT_ID
DEPLOYED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "Config saved to .pages-deploy-config"
