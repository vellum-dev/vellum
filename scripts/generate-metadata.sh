#!/bin/sh
# Generates packages-metadata.json from APKINDEX + APKBUILD metadata
# APKINDEX provides: package versions, depends, arch, license, url, pkgdesc
# APKBUILD provides: _category, _upstream_author

set -e

S3_BUCKET="${S3_BUCKET:-packages.vellum.delivery}"
METADATA_FILE="packages-metadata.json"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo '{"packages":{}}' > "$METADATA_FILE"

for arch in aarch64 armv7; do
    INDEX_URL="https://$S3_BUCKET/$arch/APKINDEX.tar.gz"
    INDEX_FILE="$WORKDIR/APKINDEX-$arch"

    echo "Fetching APKINDEX for $arch..."
    if ! curl -sf "$INDEX_URL" | tar -xzO APKINDEX > "$INDEX_FILE" 2>/dev/null; then
        echo "No APKINDEX found for $arch, skipping"
        continue
    fi

    # Parse APKINDEX entries (separated by blank lines)
    awk -v arch="$arch" '
    BEGIN { RS=""; FS="\n" }
    {
        pkg=""; ver=""; desc=""; url=""; lic=""; deps=""; provides=""
        for (i=1; i<=NF; i++) {
            if ($i ~ /^P:/) pkg = substr($i, 3)
            else if ($i ~ /^V:/) ver = substr($i, 3)
            else if ($i ~ /^T:/) desc = substr($i, 3)
            else if ($i ~ /^U:/) url = substr($i, 3)
            else if ($i ~ /^L:/) lic = substr($i, 3)
            else if ($i ~ /^D:/) deps = substr($i, 3)
            else if ($i ~ /^p:/) provides = substr($i, 3)
        }
        if (pkg && ver) {
            gsub(/"/, "\\\"", desc)
            gsub(/"/, "\\\"", url)
            print pkg "\t" ver "\t" desc "\t" url "\t" lic "\t" (deps ? deps : "_") "\t" arch "\t" (provides ? provides : "_")
        }
    }' "$INDEX_FILE" >> "$WORKDIR/all-packages.tsv"
done

[ ! -f "$WORKDIR/all-packages.tsv" ] && { echo "No packages found"; exit 0; }

for apkbuild in packages/*/APKBUILD; do
    [ -f "$apkbuild" ] || continue

    pkgname=$(grep -E '^pkgname=' "$apkbuild" | head -1 | sed 's/^pkgname=//' | tr -d '"')
    _category=$(grep -E '^_category=' "$apkbuild" | head -1 | sed 's/^_category=//' | tr -d '"')
    _upstream_author=$(grep -E '^_upstream_author=' "$apkbuild" | head -1 | sed 's/^_upstream_author=//' | tr -d '"')
    maintainer=$(grep -E '^maintainer=' "$apkbuild" | head -1 | sed 's/^maintainer=//' | tr -d '"')

    _cat="${_category:-other}"
    _auth="${_upstream_author:-unknown}"
    _maint="${maintainer:-unknown}"
    pkgdir=$(dirname "$apkbuild")
    _modsys="false"
    [ -f "$pkgdir/$pkgname.post-os-upgrade" ] && _modsys="true"
    echo "$pkgname	$_cat	$_auth	$_maint	$_modsys" >> "$WORKDIR/apkbuild-meta.tsv"

    # Extract subpackages (may be multiline)
    subpackages=$(awk '/^subpackages="/{flag=1; sub(/^subpackages="/, ""); if (/"$/) {sub(/"$/, ""); print; next}} flag{if (/"$/) {sub(/"$/, ""); print; flag=0; next} print}' "$apkbuild" | tr '\n\t' '  ')

    for subpkg in $subpackages; do
        subpkg_name="${subpkg%%:*}"
        [ -z "$subpkg_name" ] && continue

        # Get function name (after : or derive from package name)
        if echo "$subpkg" | grep -q ':'; then
            func_name="${subpkg##*:}"
        else
            func_name=$(echo "$subpkg_name" | tr '-' '_')
        fi

        # Extract _category from subpackage function body, fall back to parent
        subpkg_cat=$(awk -v fn="$func_name" '
            $0 ~ "^"fn"\\(\\)" { in_func=1; next }
            in_func && /^}/ { exit }
            in_func && /_category=/ { gsub(/.*_category=["'"'"']?|["'"'"'].*/, ""); print; exit }
        ' "$apkbuild")
        subpkg_cat="${subpkg_cat:-$_cat}"

        echo "$subpkg_name	$subpkg_cat	$_auth	$_maint	$_modsys" >> "$WORKDIR/apkbuild-meta.tsv"
    done
done

while IFS='	' read -r pkg ver desc url lic deps arch provides; do
    apkbuild_line=$(grep -E "^${pkg}	" "$WORKDIR/apkbuild-meta.tsv" 2>/dev/null | head -1 || echo "$pkg	other	unknown	unknown	false")
    [ -z "$apkbuild_line" ] && apkbuild_line="$pkg	other	unknown	unknown	false"
    category=$(echo "$apkbuild_line" | cut -f2)
    author=$(echo "$apkbuild_line" | cut -f3)
    maintainer=$(echo "$apkbuild_line" | cut -f4)
    modifies_system=$(echo "$apkbuild_line" | cut -f5)
    [ -z "$modifies_system" ] && modifies_system="false"

    categories_json=$(echo "$category" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s .)
    [ -z "$categories_json" ] || [ "$categories_json" = "[]" ] && categories_json='["other"]'

    os_min=$(echo "$deps" | grep -oE 'remarkable-os>=[0-9.]+' | sed 's/remarkable-os>=//' | head -1 || true)
    os_max=$(echo "$deps" | grep -oE 'remarkable-os<[0-9.]+' | sed 's/remarkable-os<//' | head -1 || true)

    all_devices='["rm1","rm2","rmpp","rmppm"]'
    device_names="rm1 rm2 rmpp rmppm"
    pos_devices=""
    neg_devices=""
    for token in $deps; do
        case "$token" in
            rm1|rm2|rmpp|rmppm) pos_devices="$pos_devices $token" ;;
            !rm1|!rm2|!rmpp|!rmppm) neg_devices="$neg_devices ${token#!}" ;;
        esac
    done

    if [ -n "$pos_devices" ]; then
        devices=$(echo "$pos_devices" | tr ' ' '\n' | grep -v '^$' | sort -u | jq -R . | jq -s .)
    else
        devices="$all_devices"
    fi

    for excluded in $neg_devices; do
        devices=$(echo "$devices" | jq --arg dev "$excluded" 'map(select(. != $dev))')
    done

    conflicts=$(echo "$deps" | tr ' ' '\n' | grep '^!' | grep -vE '^!(rm1|rm2|rmpp|rmppm)$' | sed 's/!//' | jq -R . | jq -s . 2>/dev/null)
    [ -z "$conflicts" ] && conflicts="[]"

    regular_deps=$(echo "$deps" | tr ' ' '\n' | grep -vE '^remarkable-os|^rm1$|^rm2$|^rmpp$|^rmppm$|^!|^aarch64$|^armv7$|^noarch$|^/bin/sh$|^_$' | grep -vE '^\|$' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null)
    [ -z "$regular_deps" ] && regular_deps="[]"

    provides_arr=$(echo "$provides" | tr ' ' '\n' | grep -vE '^$|^_$' | jq -R . | jq -s . 2>/dev/null)
    [ -z "$provides_arr" ] && provides_arr="[]"

    existing_arch=$(jq -r --arg pkg "$pkg" --arg ver "$ver" '.packages[$pkg][$ver].arch // []' "$METADATA_FILE")

    if [ "$existing_arch" != "[]" ]; then
        jq --arg pkg "$pkg" --arg ver "$ver" --arg arch "$arch" \
           '.packages[$pkg][$ver].arch += [$arch] | .packages[$pkg][$ver].arch |= unique' \
           "$METADATA_FILE" > tmp.json && mv tmp.json "$METADATA_FILE"
    else
        jq --arg pkg "$pkg" \
           --arg ver "$ver" \
           --arg desc "$desc" \
           --arg author "$author" \
           --arg maintainer "$maintainer" \
           --argjson categories "$categories_json" \
           --arg lic "$lic" \
           --arg url "$url" \
           --arg os_min "${os_min:-}" \
           --arg os_max "${os_max:-}" \
           --argjson devices "$devices" \
           --argjson conflicts "$conflicts" \
           --argjson deps "$regular_deps" \
           --argjson provides "$provides_arr" \
           --arg arch "$arch" \
           --argjson modifies_system "$modifies_system" \
           '.packages[$pkg][$ver] = {
             pkgdesc: $desc,
             upstream_author: $author,
             maintainer: $maintainer,
             categories: $categories,
             license: $lic,
             url: $url,
             os_min: (if $os_min == "" then null else $os_min end),
             os_max: (if $os_max == "" then null else $os_max end),
             devices: $devices,
             depends: $deps,
             conflicts: $conflicts,
             provides: $provides,
             arch: [$arch],
             modifies_system: $modifies_system
           }' "$METADATA_FILE" > tmp.json && mv tmp.json "$METADATA_FILE"
    fi

    echo "Processed: $pkg $ver ($arch)"
done < "$WORKDIR/all-packages.tsv"

# Compute reverse conflicts (if A conflicts with B, B should also show conflict with A)
echo "Computing reverse conflicts..."
jq '
  ([.packages | to_entries[] | .key as $pkg | .value | to_entries[] | .value.conflicts[] | {target: ., source: $pkg}] |
   reduce .[] as $c ({}; .[$c.target] += [$c.source])) as $reverse |
  .packages |= with_entries(
    .key as $pkg |
    .value |= with_entries(
      .value.conflicts += ($reverse[$pkg] // []) |
      .value.conflicts |= unique
    )
  )
' "$METADATA_FILE" > tmp.json && mv tmp.json "$METADATA_FILE"

jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.generated = $ts' "$METADATA_FILE" > tmp.json && mv tmp.json "$METADATA_FILE"

echo "Generated $METADATA_FILE"
