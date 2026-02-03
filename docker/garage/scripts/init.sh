#!/bin/sh
set -e

# Install dependencies
apk add --no-cache curl jq >/dev/null

ADMIN_API="http://garage:3903"
AUTH="Authorization: Bearer ${GARAGE_ADMIN_TOKEN}"

echo "Waiting for Garage admin API..."
until curl -sf -H "$AUTH" "$ADMIN_API/v2/GetClusterHealth" >/dev/null 2>&1; do
  sleep 1
done
echo "Garage is ready!"

# Get cluster status and node ID (v2 API returns nodes array)
echo "Getting node ID..."
NODE_ID=$(curl -sf -H "$AUTH" "$ADMIN_API/v2/GetClusterStatus" | jq -r '.nodes[0].id')
echo "Node ID: $NODE_ID"

# Check current layout version
LAYOUT=$(curl -sf -H "$AUTH" "$ADMIN_API/v2/GetClusterLayout")
CURRENT_VERSION=$(echo "$LAYOUT" | jq '.version')
ROLES_COUNT=$(echo "$LAYOUT" | jq '.roles | length')

if [ "$ROLES_COUNT" = "0" ]; then
  # Assign node to layout (v2 API uses "roles" wrapper)
  echo "Assigning node to layout..."
  curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$ADMIN_API/v2/UpdateClusterLayout" \
    -d "{\"roles\": [{\"id\": \"$NODE_ID\", \"zone\": \"dc1\", \"capacity\": 1073741824, \"tags\": []}]}" >/dev/null

  # Apply layout
  echo "Applying layout..."
  curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$ADMIN_API/v2/ApplyClusterLayout" \
    -d "{\"version\": $((CURRENT_VERSION + 1))}" >/dev/null
  echo "Layout applied"
else
  echo "Layout already configured"
fi

# Check if key exists (API returns object if found, empty/error if not)
echo "Setting up access key..."
KEY_INFO=$(curl -sf -H "$AUTH" "$ADMIN_API/v2/GetKeyInfo?id=${S3_ACCESS_KEY}" 2>/dev/null || echo "")

if [ -z "$KEY_INFO" ]; then
  curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$ADMIN_API/v2/ImportKey" \
    -d "{\"accessKeyId\": \"${S3_ACCESS_KEY}\", \"secretAccessKey\": \"${S3_SECRET_KEY}\", \"name\": \"backup-key\"}" >/dev/null
  echo "Key created"
else
  echo "Key already exists"
fi

# Key ID is the access key ID itself
KEY_ID="${S3_ACCESS_KEY}"
echo "Key ID: $KEY_ID"

# Check if bucket exists (API returns object if found, empty if not)
echo "Setting up bucket..."
BUCKET_INFO=$(curl -sf -H "$AUTH" "$ADMIN_API/v2/GetBucketInfo?globalAlias=${S3_BUCKET}" 2>/dev/null || echo "")

if [ -z "$BUCKET_INFO" ]; then
  BUCKET_RESP=$(curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
    "$ADMIN_API/v2/CreateBucket" \
    -d "{\"globalAlias\": \"${S3_BUCKET}\"}")
  BUCKET_ID=$(echo "$BUCKET_RESP" | jq -r '.id')
  echo "Bucket created: $BUCKET_ID"
else
  BUCKET_ID=$(echo "$BUCKET_INFO" | jq -r '.id')
  echo "Bucket exists: $BUCKET_ID"
fi

# Grant permissions
echo "Granting bucket permissions..."
curl -sf -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$ADMIN_API/v2/AllowBucketKey" \
  -d "{\"bucketId\": \"$BUCKET_ID\", \"accessKeyId\": \"$KEY_ID\", \"permissions\": {\"read\": true, \"write\": true, \"owner\": true}}" >/dev/null || true

echo "Garage initialization complete!"
