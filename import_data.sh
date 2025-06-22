#!/bin/bash

# Constants
base_uri="http://geoserver:8080/geoserver/rest"
workspace="osm_shortbread"
store="osm"
style_name="versatile-simple"
credentials="admin:geoserver"

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting GeoServer data import process...${NC}"

# Function to check HTTP response code
check_response() {
    local response_code=$1
    local operation=$2
    
    if [[ $response_code =~ ^2[0-9][0-9]$ ]]; then
        echo -e "${GREEN}✓ $operation completed successfully (HTTP $response_code)${NC}"
        return 0
    else
        echo -e "${RED}✗ $operation failed (HTTP $response_code)${NC}"
        return 1
    fi
}

# Wait for GeoServer to be ready
echo -e "${YELLOW}Waiting for GeoServer to be ready...${NC}"
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if curl -s -f -u "$credentials" "$base_uri/about/version" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ GeoServer is ready${NC}"
        break
    fi
    attempt=$((attempt + 1))
    echo "Attempt $attempt/$max_attempts - waiting for GeoServer..."
    sleep 5
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}✗ GeoServer failed to start within expected time${NC}"
    exit 1
fi

# Step 1: Create workspace
echo -e "${YELLOW}Step 1: Creating workspace '$workspace'...${NC}"
response=$(curl -s -w "%{http_code}" -u "$credentials" -XPOST -H "Content-type: text/xml" \
    -d "<workspace><name>$workspace</name></workspace>" \
    "$base_uri/workspaces")

response_code="${response: -3}"
if ! check_response "$response_code" "Workspace creation"; then
    if [ "$response_code" = "409" ]; then
        echo -e "${YELLOW}  Workspace already exists, continuing...${NC}"
    else
        echo -e "${RED}  Unexpected error creating workspace${NC}"
        exit 1
    fi
fi

# Step 2: Create datastore
echo -e "${YELLOW}Step 2: Creating datastore '$store'...${NC}"
response=$(curl -s -w "%{http_code}" -u "$credentials" -XPOST -H "Content-type: text/xml" \
    "$base_uri/workspaces/$workspace/datastores/" \
    -d "<dataStore>
 <name>$store</name>
 <type>MBTiles with vector tiles</type>
 <enabled>true</enabled>
 <workspace>
  <name>$workspace</name>
 </workspace>
 <connectionParameters>
  <entry key=\"database\">file:///data/shortbread.mbtiles</entry>
  <entry key=\"dbtype\">mbtiles</entry>
  <entry key=\"namespace\">$workspace</entry>
 </connectionParameters>
</dataStore>")

response_code="${response: -3}"
if ! check_response "$response_code" "Datastore creation"; then
    if [ "$response_code" = "409" ]; then
        echo -e "${YELLOW}  Datastore already exists, continuing...${NC}"
    else
        echo -e "${RED}  Error creating datastore${NC}"
        exit 1
    fi
fi

# Step 3: Get available feature types
echo -e "${YELLOW}Step 3: Retrieving available feature types...${NC}"
response=$(curl -s -w "%{http_code}" -u "$credentials" \
    "$base_uri/workspaces/$workspace/datastores/$store/featuretypes.xml?list=available")

response_code="${response: -3}"
response_body="${response%???}"

if ! check_response "$response_code" "Feature types retrieval"; then
    echo -e "${RED}  Failed to retrieve feature types${NC}"
    exit 1
fi

# Extract feature type names using grep and sed
feature_types_raw=$(echo "$response_body" | grep -o '<featureTypeName>[^<]*</featureTypeName>' | sed 's/<featureTypeName>\(.*\)<\/featureTypeName>/\1/')

# Count feature types
feature_count=$(echo "$feature_types_raw" | wc -l)
echo -e "${GREEN}  Found $feature_count feature types to publish${NC}"

# Display feature types
echo "$feature_types_raw" | while read -r ft; do
    if [ -n "$ft" ]; then
        echo "    - $ft"
    fi
done

# Step 4: Publish all feature types
echo -e "${YELLOW}Step 4: Publishing feature types...${NC}"

# Create temporary files for counters (to work around subshell issues)
published_count=0
failed_count=0

for feature_type in $feature_types_raw; do
    if [ -z "$feature_type" ]; then
        continue
    fi
    echo -e "${YELLOW}  Publishing '$feature_type'...${NC}"
    
    response=$(curl -s -w "%{http_code}" -u "$credentials" \
        "$base_uri/workspaces/$workspace/datastores/$store/featuretypes" \
        -X POST -H "Content-Type: application/xml" \
        -d "<featureType>
  <nativeName>$feature_type</nativeName>
  <title>$feature_type</title>
  <namespace>
    <name>$workspace</name>
  </namespace>
  <store class=\"dataStore\">
    <name>$workspace:$store</name>
  </store>
</featureType>")
    
    response_code="${response: -3}"
    if check_response "$response_code" "Publishing '$feature_type'"; then
        published_count=$((published_count + 1))
    else
        if [ "$response_code" = "409" ]; then
            echo -e "${YELLOW}    Feature type '$feature_type' already exists, skipping...${NC}"
            published_count=$((published_count + 1))
        else
            echo -e "${RED}    Failed to publish '$feature_type'${NC}"
            failed_count=$((failed_count + 1))
        fi
    fi
done

# Step 5: Create MBStyle
echo -e "${YELLOW}Step 5: Creating MBStyle '$style_name'...${NC}"

# First create the style definition in the workspace
response=$(curl -s -w "%{http_code}" -u "$credentials" -X POST \
    -H "Content-Type: application/xml" \
    "$base_uri/workspaces/$workspace/styles" \
    -d "<style>
  <name>$style_name</name>
  <format>mbstyle</format>
  <filename>$style_name.mbstyle</filename>
  <workspace>$workspace</workspace>
</style>")

response_code="${response: -3}"
if ! check_response "$response_code" "Style definition creation"; then
    if [ "$response_code" = "409" ]; then
        echo -e "${YELLOW}  Style already exists, updating...${NC}"
    else
        echo -e "${RED}  Failed to create style definition (HTTP $response_code)${NC}"
        echo -e "${YELLOW}  Continuing without style creation...${NC}"
        # Don't exit, just skip style creation
        style_created=false
    fi
else
    style_created=true
fi

# Then upload the style content if style was created successfully
if [ "$style_created" = "true" ] && [ -f "/styles/versatile-style.mbstyle" ]; then
    echo -e "${YELLOW}  Uploading style content...${NC}"
    response=$(curl -s -w "%{http_code}" -u "$credentials" -X PUT \
        -H "Content-Type: application/vnd.geoserver.mbstyle+json" \
        --data-binary "@/styles/versatile-style.mbstyle" \
        "$base_uri/workspaces/$workspace/styles/$style_name")
    
    response_code="${response: -3}"
    if check_response "$response_code" "Style content upload"; then
        echo -e "${GREEN}  ✓ MBStyle '$style_name' created successfully${NC}"
    else
        echo -e "${RED}  Failed to upload style content (HTTP $response_code)${NC}"
    fi
elif [ ! -f "/styles/versatile-style.mbstyle" ]; then
    echo -e "${RED}  Style file not found: /styles/versatile-style.mbstyle${NC}"
fi

# Step 6: Create Layer Group with Style Group
echo -e "${YELLOW}Step 6: Creating layer group 'osm-shortbread'...${NC}"

response=$(curl -s -w "%{http_code}" -u "$credentials" -X POST \
    -H "Content-Type: application/xml" \
    "$base_uri/workspaces/$workspace/layergroups" \
    -d "<layerGroup>
<name>osm-shortbread</name>
<mode>SINGLE</mode>
<title>osm-shortbread</title>
<workspace>
  <name>$workspace</name>
</workspace>
<publishables>
<published/>
</publishables>
<styles>
 <style>
  <name>$workspace:$style_name</name>
 </style>
</styles>
</layerGroup>")

response_code="${response: -3}"
if ! check_response "$response_code" "Layer group creation"; then
    if [ "$response_code" = "409" ]; then
        echo -e "${YELLOW}  Layer group already exists, skipping...${NC}"
    else
        echo -e "${RED}  Failed to create layer group (HTTP $response_code)${NC}"
        echo -e "${YELLOW}  You can create it manually in GeoServer admin interface${NC}"
    fi
else
    echo -e "${GREEN}  ✓ Layer group 'osm-shortbread' created successfully${NC}"
fi

# Step 7: Configure WMS settings for memory optimization
echo -e "${YELLOW}Step 7: Configuring WMS settings...${NC}"

# Get current WMS settings
wms_response=$(curl -s -w "%{http_code}" -u "$credentials" \
    "$base_uri/services/wms/settings.xml")

wms_response_code="${wms_response: -3}"
wms_body="${wms_response%???}"

if check_response "$wms_response_code" "WMS settings retrieval"; then
    # Update maxRequestMemory to 0 using sed
    updated_wms=$(echo "$wms_body" | sed 's/<maxRequestMemory>[^<]*<\/maxRequestMemory>/<maxRequestMemory>0<\/maxRequestMemory>/')
    
    # PUT the updated settings back
    echo -e "${YELLOW}  Updating WMS maxRequestMemory to 0...${NC}"
    update_response=$(curl -s -w "%{http_code}" -u "$credentials" \
        -X PUT -H "Content-Type: application/xml" \
        -d "$updated_wms" \
        "$base_uri/services/wms/settings")
    
    update_response_code="${update_response: -3}"
    if check_response "$update_response_code" "WMS settings update"; then
        echo -e "${GREEN}  ✓ WMS settings updated successfully${NC}"
    else
        echo -e "${RED}  Failed to update WMS settings (HTTP $update_response_code)${NC}"
        echo -e "${YELLOW}  You may need to manually set maxRequestMemory to 0 in WMS settings${NC}"
    fi
else
    echo -e "${RED}  Failed to retrieve WMS settings (HTTP $wms_response_code)${NC}"
    echo -e "${YELLOW}  You may need to manually configure WMS settings${NC}"
fi

# Summary
echo -e "${YELLOW}Import process completed!${NC}"
echo -e "${GREEN}✓ Successfully published: $published_count feature types${NC}"
if [ $failed_count -gt 0 ]; then
    echo -e "${RED}✗ Failed to publish: $failed_count feature types${NC}"
fi

echo -e "${GREEN}GeoServer is now ready with your MBTiles data!${NC}"
echo -e "${YELLOW}Access GeoServer at: http://localhost/geoserver${NC}"
echo -e "${YELLOW}Credentials: admin / *******${NC}"
