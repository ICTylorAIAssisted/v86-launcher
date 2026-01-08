#!/bin/bash
#
# Deploy v86 Session Sync Worker to Cloudflare
#
# Prerequisites:
#   - Cloudflare account
#   - API token with Workers permissions (Account > Workers Scripts: Edit, 
#     Account > Workers KV Storage: Edit)
#   - jq installed (for JSON parsing)
#
# Usage:
#   ./deploy.sh
#
# Environment variables (or will prompt):
#   CF_API_TOKEN    - Cloudflare API token
#   CF_ACCOUNT_ID   - Cloudflare account ID (found in dashboard URL or Workers overview)
#

set -e

WORKER_NAME="v86-session-sync"
KV_NAMESPACE_NAME="v86-session-data"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check for jq
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed.${NC}"
    echo "Install with: brew install jq (macOS) or apt install jq (Ubuntu)"
    exit 1
fi

echo -e "${GREEN}=== v86 Session Sync Worker Deployment ===${NC}\n"

# Get credentials
if [ -z "$CF_API_TOKEN" ]; then
    echo -e "${YELLOW}Cloudflare API Token not set.${NC}"
    echo "Create one at: https://dash.cloudflare.com/profile/api-tokens"
    echo "Required permissions: Account > Workers Scripts: Edit, Account > Workers KV Storage: Edit"
    echo ""
    read -p "Enter API Token: " CF_API_TOKEN
fi

if [ -z "$CF_ACCOUNT_ID" ]; then
    echo -e "${YELLOW}Cloudflare Account ID not set.${NC}"
    echo "Find it at: https://dash.cloudflare.com → Workers & Pages → Overview (right sidebar)"
    echo ""
    read -p "Enter Account ID: " CF_ACCOUNT_ID
fi

API_BASE="https://api.cloudflare.com/client/v4"

# Helper function for API calls
cf_api() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    if [ -n "$data" ]; then
        curl -s -X "$method" \
            "$API_BASE$endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" \
            "$API_BASE$endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN"
    fi
}

# Helper function to check if API response was successful
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
VERIFY=$(cf_api GET "/user/tokens/verify")
check_success "$VERIFY" "Invalid API token"
echo -e "${GREEN}✓ Token valid${NC}\n"

# Step 1: Create or get KV namespace
echo "Setting up KV namespace..."
KV_LIST=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces")
check_success "$KV_LIST" "Failed to list KV namespaces"

# Check if namespace exists
KV_ID=$(echo "$KV_LIST" | jq -r --arg name "$KV_NAMESPACE_NAME" '.result[] | select(.title == $name) | .id')

if [ -z "$KV_ID" ] || [ "$KV_ID" = "null" ]; then
    echo "Creating KV namespace: $KV_NAMESPACE_NAME"
    KV_CREATE=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces" \
        "{\"title\":\"$KV_NAMESPACE_NAME\"}")
    
    check_success "$KV_CREATE" "Failed to create KV namespace"
    
    KV_ID=$(echo "$KV_CREATE" | jq -r '.result.id')
    echo -e "${GREEN}✓ Created KV namespace: $KV_ID${NC}"
else
    echo -e "${GREEN}✓ Using existing KV namespace: $KV_ID${NC}"
fi
echo ""

# Step 2: Deploy the worker
echo "Deploying worker..."

# Create metadata with KV binding
METADATA=$(jq -n \
    --arg kv_id "$KV_ID" \
    '{
        main_module: "index.js",
        bindings: [
            {
                type: "kv_namespace",
                name: "SESSION_DATA",
                namespace_id: $kv_id
            }
        ],
        compatibility_date: "2024-01-01"
    }')

# Deploy using form data (required for ES modules)
DEPLOY_RESULT=$(curl -s -X PUT \
    "$API_BASE/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER_NAME" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -F "metadata=$METADATA;type=application/json" \
    -F "index.js=@src/index.js;type=application/javascript+module")

check_success "$DEPLOY_RESULT" "Failed to deploy worker"
echo -e "${GREEN}✓ Worker deployed${NC}\n"

# Step 3: Get/enable workers.dev subdomain
echo "Enabling workers.dev route..."

# Get the workers.dev subdomain
SUBDOMAIN_RESULT=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/workers/subdomain")
SUBDOMAIN=$(echo "$SUBDOMAIN_RESULT" | jq -r '.result.subdomain // empty')

if [ -z "$SUBDOMAIN" ]; then
    echo -e "${YELLOW}No workers.dev subdomain configured.${NC}"
    echo "Please enable workers.dev subdomain in your Cloudflare dashboard"
    WORKER_URL="(configure workers.dev subdomain in dashboard)"
else
    # Enable the route
    ENABLE_RESULT=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER_NAME/subdomain" \
        '{"enabled":true}')
    
    # Check success but don't fail if already enabled
    if echo "$ENABLE_RESULT" | jq -e '.success == true' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ workers.dev route enabled${NC}"
    else
        echo -e "${YELLOW}Note: Could not enable route (may already be enabled)${NC}"
    fi
    
    WORKER_URL="https://$WORKER_NAME.$SUBDOMAIN.workers.dev"
    echo -e "${GREEN}✓ Worker URL: $WORKER_URL${NC}"
fi

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
echo "Worker URL: $WORKER_URL"
echo "KV Namespace ID: $KV_ID"
echo ""
echo "Test with:"
echo "  curl $WORKER_URL/health"
echo ""
echo "Next steps:"
echo "  1. Update SYNC_CONFIG.workerUrl in your index.html"
echo "  2. Share session URLs with viewers"
echo ""

# Save config for later reference
cat > .deploy-config <<EOF
WORKER_URL=$WORKER_URL
KV_NAMESPACE_ID=$KV_ID
CF_ACCOUNT_ID=$CF_ACCOUNT_ID
EOF

echo "Config saved to .deploy-config"
