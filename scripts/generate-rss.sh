#!/bin/sh
# Generates RSS 2.0 feeds from packages-metadata.json
# Output: feeds/all.rss, feeds/rm1.rss, feeds/rm2.rss, feeds/rmpp.rss, feeds/rmppm.rss

set -e

METADATA_FILE="${1:-packages-metadata.json}"
FEEDS_DIR="feeds"
MAX_ITEMS="${MAX_ITEMS:-0}"

if [ ! -f "$METADATA_FILE" ]; then
    echo "Error: $METADATA_FILE not found"
    exit 1
fi

mkdir -p "$FEEDS_DIR"

iso_to_rfc822() {
    # Convert ISO 8601 (2024-01-15T10:30:00Z) to RFC 822 (Mon, 15 Jan 2024 10:30:00 +0000)
    if command -v gdate >/dev/null 2>&1; then
        gdate -d "$1" -R 2>/dev/null || echo "$1"
    elif date --version 2>/dev/null | grep -q GNU; then
        date -d "$1" -R 2>/dev/null || echo "$1"
    else
        # macOS date fallback - parse and reformat
        date -jf "%Y-%m-%dT%H:%M:%SZ" "$1" "+%a, %d %b %Y %H:%M:%S +0000" 2>/dev/null || echo "$1"
    fi
}

generate_feed() {
    local filter="$1"
    local output="$2"
    local title="$3"
    local description="$4"

    echo "Generating $output..."

    # Extract items from metadata, apply filter, sort by date
    items=$(jq -r --arg filter "$filter" '
        [.packages | to_entries[] | .key as $pkg | .value | to_entries[] |
            {
                pkg: $pkg,
                ver: .key,
                desc: .value.pkgdesc,
                url: .value.url,
                author: .value.upstream_author,
                categories: .value.categories,
                devices: .value.devices,
                os_min: .value.os_min,
                os_max: .value.os_max,
                released: .value.released
            }
        ] |
        if $filter == "all" then .
        else [.[] | select(.devices | index($filter))]
        end |
        sort_by(.released) | reverse
    ' "$METADATA_FILE")

    # Get build date
    build_date=$(jq -r '.generated // empty' "$METADATA_FILE")
    if [ -n "$build_date" ]; then
        build_date_rfc=$(iso_to_rfc822 "$build_date")
    else
        build_date_rfc=$(date -R 2>/dev/null || date "+%a, %d %b %Y %H:%M:%S %z")
    fi

    # Start RSS document
    cat > "$output" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>$title</title>
    <link>https://vellum.delivery</link>
    <description>$description</description>
    <language>en-us</language>
    <lastBuildDate>$build_date_rfc</lastBuildDate>
    <atom:link href="https://packages.vellum.delivery/feeds/$(basename "$output")" rel="self" type="application/rss+xml"/>
EOF

    # Add items
    echo "$items" | jq -r --argjson max "$MAX_ITEMS" '
        (if $max > 0 then .[:$max] else . end)[] |
        @base64
    ' | while read -r item_b64; do
        item=$(echo "$item_b64" | base64 -d)

        pkg=$(echo "$item" | jq -r '.pkg')
        ver=$(echo "$item" | jq -r '.ver')
        desc=$(echo "$item" | jq -r '.desc // "No description"')
        url=$(echo "$item" | jq -r '.url // "https://vellum.delivery"')
        author=$(echo "$item" | jq -r '.author // "unknown"')
        released=$(echo "$item" | jq -r '.released // empty')
        categories=$(echo "$item" | jq -r '.categories // [] | join(", ")')
        devices=$(echo "$item" | jq -r '.devices // [] | join(", ")')
        os_min=$(echo "$item" | jq -r '.os_min // empty')
        os_max=$(echo "$item" | jq -r '.os_max // empty')

        # Convert date
        if [ -n "$released" ]; then
            pub_date=$(iso_to_rfc822 "$released")
        else
            pub_date="$build_date_rfc"
        fi

        # Build OS version string
        os_line=""
        if [ -n "$os_min" ] && [ -n "$os_max" ]; then
            os_line="OS: $os_min - $os_max"
        elif [ -n "$os_min" ]; then
            os_line="OS: $os_min+"
        fi

        # Build full description with HTML line breaks
        full_desc="$desc<br/>Devices: $devices"
        [ -n "$os_line" ] && full_desc="$full_desc<br/>$os_line"

        # Escape XML special characters in author
        author_escaped=$(printf '%s' "$author" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

        cat >> "$output" << EOF
    <item>
      <title>$pkg $ver</title>
      <link>$url</link>
      <description><![CDATA[$full_desc]]></description>
      <author>$author_escaped</author>
      <category>$categories</category>
      <pubDate>$pub_date</pubDate>
      <guid isPermaLink="false">$pkg-$ver</guid>
    </item>
EOF
    done

    # Close RSS document
    cat >> "$output" << EOF
  </channel>
</rss>
EOF

    if [ "$MAX_ITEMS" -gt 0 ]; then
        echo "Generated $output (max $MAX_ITEMS items)"
    else
        echo "Generated $output"
    fi
}

# Generate all feeds
generate_feed "all" "$FEEDS_DIR/all.rss" \
    "Vellum Packages - All" \
    "All package updates for reMarkable tablets"

generate_feed "rm1" "$FEEDS_DIR/rm1.rss" \
    "Vellum Packages - reMarkable 1" \
    "Package updates for reMarkable 1"

generate_feed "rm2" "$FEEDS_DIR/rm2.rss" \
    "Vellum Packages - reMarkable 2" \
    "Package updates for reMarkable 2"

generate_feed "rmpp" "$FEEDS_DIR/rmpp.rss" \
    "Vellum Packages - reMarkable Paper Pro" \
    "Package updates for reMarkable Paper Pro"

generate_feed "rmppm" "$FEEDS_DIR/rmppm.rss" \
    "Vellum Packages - reMarkable Paper Pro Move" \
    "Package updates for reMarkable Paper Pro Move"

echo "All feeds generated in $FEEDS_DIR/"
