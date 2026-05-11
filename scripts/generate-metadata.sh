#!/bin/bash
# Generates packages-metadata.json from APKINDEX + VELBUILD metadata
# APKINDEX provides: package versions, depends, arch, license, url, pkgdesc
# VELBUILD provides: category, upstream_author

set -e

S3_BUCKET="${S3_BUCKET:-packages.vellum.delivery}"
S3_REGION="${S3_REGION:-us-east-2}"
S3_PREFIX="${S3_PREFIX:-}"
PREFIX_PATH="${S3_PREFIX:+$S3_PREFIX/}"
S3_URL="https://s3.$S3_REGION.amazonaws.com/$S3_BUCKET"
METADATA_FILE="packages-metadata.json"
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

# Fetch existing metadata to preserve release timestamps
echo "Fetching existing metadata for timestamp preservation..."
if curl -sf "$S3_URL/${PREFIX_PATH}packages-metadata.json" -o "$WORKDIR/old-metadata.json" 2>/dev/null; then
    echo "Found existing metadata"
else
    echo "No existing metadata found, starting fresh"
    echo '{"packages":{}}' >"$WORKDIR/old-metadata.json"
fi

echo '{"packages":{}}' >"$METADATA_FILE"

for arch in aarch64 armv7; do
    INDEX_URL="$S3_URL/${PREFIX_PATH}$arch/APKINDEX.tar.gz"
    INDEX_FILE="$WORKDIR/APKINDEX-$arch"

    echo "Fetching APKINDEX for $arch..."
    if ! curl -sf "$INDEX_URL" | tar -xzO APKINDEX >"$INDEX_FILE" 2>/dev/null; then
        echo "No APKINDEX found for $arch, skipping"
        continue
    fi

    # Parse APKINDEX entries (separated by blank lines)
    awk -v arch="$arch" '
    BEGIN { RS=""; FS="\n" }
    {
        pkg=""; ver=""; desc=""; url=""; lic=""; deps=""; provides=""; install_if=""; origin=""; maint=""
        for (i=1; i<=NF; i++) {
            if ($i ~ /^P:/) pkg = substr($i, 3)
            else if ($i ~ /^V:/) ver = substr($i, 3)
            else if ($i ~ /^T:/) desc = substr($i, 3)
            else if ($i ~ /^U:/) url = substr($i, 3)
            else if ($i ~ /^L:/) lic = substr($i, 3)
            else if ($i ~ /^D:/) deps = substr($i, 3)
            else if ($i ~ /^p:/) provides = substr($i, 3)
            else if ($i ~ /^i:/) install_if = substr($i, 3)
            else if ($i ~ /^o:/) origin = substr($i, 3)
            else if ($i ~ /^m:/) maint = substr($i, 3)
        }
        if (pkg && ver) {
            gsub(/"/, "\\\"", desc)
            gsub(/"/, "\\\"", url)
            gsub(/"/, "\\\"", maint)
            print pkg "\t" ver "\t" desc "\t" url "\t" lic "\t" (deps ? deps : "_") "\t" arch "\t" (provides ? provides : "_") "\t" (install_if ? install_if : "_") "\t" (origin ? origin : "_") "\t" (maint ? maint : "_")
        }
    }' "$INDEX_FILE" >>"$WORKDIR/all-packages.tsv"
done

[ ! -f "$WORKDIR/all-packages.tsv" ] && {
    echo "No packages found"
    exit 0
}

for velbuild in packages/*/VELBUILD; do
    [ -f "$velbuild" ] || continue

    unset pkgname pkgver pkgrel upstream_author category maintainer status \
          readmeurl donateurl subpackages url arch license depends options \
          source pkgdesc
    . "$velbuild"
    _cat="${category:-other}"
    _auth="${upstream_author:-unknown}"
    _maint="${maintainer:-unknown}"
    _status="${status:-maintained}"
    _modsys="false"
    grep -q '^postosupgrade()' "$velbuild" && _modsys="true"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${pkgname:?pkgname missing}" \
        "$_cat" \
        "$_auth" \
        "$_maint" \
        "$_modsys" \
        "$readmeurl" \
        "$donateurl" \
        "$_status" \
        >>"$WORKDIR/apkbuild-meta.tsv"
    for subpkg in $subpackages; do
        subpkg_name="${subpkg%%:*}"
        [ -z "$subpkg_name" ] && continue

        # Get function name (after : or derive from package name)
        if echo "$subpkg" | grep -q ':'; then
            func_name="${subpkg##*:}"
        else
            func_name=$(echo "$subpkg_name" | tr '-' '_')
        fi

        # Extract category from subpackage function body, fall back to parent
        subpkg_cat=$(awk -v fn="$func_name" '
            $0 ~ "^"fn"\\(\\)" { in_func=1; next }
            in_func && /^}/ { exit }
            in_func && /category=/ { gsub(/.*category=["'"'"']?|["'"'"'].*/, ""); print; exit }
        ' "$velbuild")
        subpkg_cat="${subpkg_cat:-$_cat}"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$subpkg_name" \
            "$subpkg_cat" \
            "$_auth" \
            "$_maint" \
            "$_modsys" \
            "$readmeurl" \
            "$donateurl" \
            "$_status" \
            >>"$WORKDIR/apkbuild-meta.tsv"
    done
done

while IFS='	' read -r pkg ver desc url lic deps arch provides install_if origin apkindex_maint <&3; do
    # Try to get metadata from VELBUILD - first check the package itself, then fall back to origin (parent)
    apkbuild_line=$(grep -E "^${pkg}	" "$WORKDIR/apkbuild-meta.tsv" 2>/dev/null | head -1 || true)
    if [ -z "$apkbuild_line" ] && [ -n "$origin" ] && [ "$origin" != "_" ] && [ "$origin" != "$pkg" ]; then
        apkbuild_line=$(grep -E "^${origin}	" "$WORKDIR/apkbuild-meta.tsv" 2>/dev/null | head -1 || true)
    fi
    [ -z "$apkbuild_line" ] && apkbuild_line="$pkg	other	unknown	unknown	false			deprecated"

    category=$(echo "$apkbuild_line" | cut -f2)
    author=$(echo "$apkbuild_line" | cut -f3)
    maintainer=$(echo "$apkbuild_line" | cut -f4)
    modifies_system=$(echo "$apkbuild_line" | cut -f5)
    readmeurl=$(echo "$apkbuild_line" | cut -f6)
    donateurl=$(echo "$apkbuild_line" | cut -f7)
    status=$(echo "$apkbuild_line" | cut -f8)
    [ -z "$modifies_system" ] && modifies_system="false"

    # Use APKINDEX maintainer as fallback
    if [ "$maintainer" = "unknown" ] && [ -n "$apkindex_maint" ] && [ "$apkindex_maint" != "_" ]; then
        maintainer="$apkindex_maint"
    fi

    categories_json=$(echo "$category" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s .)
    [ -z "$categories_json" ] || [ "$categories_json" = "[]" ] && categories_json='["other"]'

    os_min=$(echo "$deps" | grep -oE 'remarkable-os>=[0-9.]+' | sed 's/remarkable-os>=//' | head -1 || true)
    os_max=$(echo "$deps" | grep -oE 'remarkable-os<[0-9.]+' | sed 's/remarkable-os<//' | head -1 || true)

    os_constraints="[]"
    for token in $deps; do
        case "$token" in
        remarkable-os\>=*)
            version="${token#remarkable-os>=}"
            os_constraints=$(echo "$os_constraints" | jq --arg v "$version" '. += [{"version": $v, "operator": ">="}]')
            ;;
        remarkable-os\<=*)
            version="${token#remarkable-os<=}"
            os_constraints=$(echo "$os_constraints" | jq --arg v "$version" '. += [{"version": $v, "operator": "<="}]')
            ;;
        remarkable-os\>*)
            version="${token#remarkable-os>}"
            os_constraints=$(echo "$os_constraints" | jq --arg v "$version" '. += [{"version": $v, "operator": ">"}]')
            ;;
        remarkable-os\<*)
            version="${token#remarkable-os<}"
            os_constraints=$(echo "$os_constraints" | jq --arg v "$version" '. += [{"version": $v, "operator": "<"}]')
            ;;
        remarkable-os=*)
            version="${token#remarkable-os=}"
            os_constraints=$(echo "$os_constraints" | jq --arg v "$version" '. += [{"version": $v, "operator": "="}]')
            ;;
        esac
    done

    all_devices='["rm1","rm2","rmpp","rmppm","rmppmove","rmppure"]'
    device_names="rm1 rm2 rmpp rmppm rmppmove rmppure"
    pos_devices=""
    neg_devices=""

    # Check depends for device constraints
    for token in $deps; do
        case "$token" in
        rm1 | rm2 | rmpp | rmppm | rmppmove | rmppure) pos_devices="$pos_devices $token" ;;
        !rm1 | !rm2 | !rmpp | !rmppm | !rmppmove | !rmppure) neg_devices="$neg_devices ${token#!}" ;;
        esac
    done

    # Check install_if for device constraints
    if [ -n "$install_if" ] && [ "$install_if" != "_" ]; then
        for token in $install_if; do
            case "$token" in
            rm1 | rm2 | rmpp | rmppm | rmppmove | rmppure) pos_devices="$pos_devices $token" ;;
            esac
        done
    fi

    if [ -n "$pos_devices" ]; then
        devices=$(echo "$pos_devices" | tr ' ' '\n' | grep -v '^$' | sort -u | jq -R . | jq -s .)
    else
        devices="$all_devices"
    fi

    for excluded in $neg_devices; do
        devices=$(echo "$devices" | jq --arg dev "$excluded" 'map(select(. != $dev))')
        if [ "$excluded" = "rmppm" ] || [ "$excluded" = "rmppmove" ]; then
            devices=$(echo "$devices" | jq 'map(select(. != "rmppm" and . != "rmppmove"))')
        fi
    done

    conflicts=$(echo "$deps" | tr ' ' '\n' | grep '^!' | grep -vE '^!(rm1|rm2|rmpp|rmppm|rmppmove|rmppure)$' | sed 's/!//' | jq -R . | jq -s . 2>/dev/null)
    [ -z "$conflicts" ] && conflicts="[]"

    regular_deps=$(echo "$deps" | tr ' ' '\n' | grep -vE '^remarkable-os|^rm1$|^rm2$|^rmpp$|^rmppm$|^rmppmove$|^rmppure$|^!|^aarch64$|^armv7$|^noarch$|^/bin/sh$|^_$' | grep -vE '^\|$' | grep -v '^$' | jq -R . | jq -s . 2>/dev/null)
    [ -z "$regular_deps" ] && regular_deps="[]"

    provides_arr=$(echo "$provides" | tr ' ' '\n' | grep -vE '^$|^_$' | jq -R . | jq -s . 2>/dev/null)
    [ -z "$provides_arr" ] && provides_arr="[]"

    existing_arch=$(jq -r --arg pkg "$pkg" --arg ver "$ver" '.packages[$pkg][$ver].arch // []' "$METADATA_FILE")

    if [ "$existing_arch" != "[]" ]; then
        jq --arg pkg "$pkg" --arg ver "$ver" --arg arch "$arch" \
            '.packages[$pkg][$ver].arch += [$arch] | .packages[$pkg][$ver].arch |= unique' \
            "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"
    else
        jq --arg pkg "$pkg" \
            --arg ver "$ver" \
            --arg desc "$desc" \
            --arg author "$author" \
            --arg maintainer "$maintainer" \
            --argjson categories "$categories_json" \
            --arg lic "$lic" \
            --arg url "$url" \
            --arg readmeurl "$readmeurl" \
            --arg donateurl "$donateurl" \
            --arg status "${status:-maintained}" \
            --arg os_min "${os_min:-}" \
            --arg os_max "${os_max:-}" \
            --argjson os_constraints "$os_constraints" \
            --argjson devices "$devices" \
            --argjson conflicts "$conflicts" \
            --argjson deps "$regular_deps" \
            --argjson provides "$provides_arr" \
            --arg arch "$arch" \
            --argjson modifies_system "$modifies_system" \
            --arg origin "${origin:-}" \
            --arg install_if_val "${install_if:-}" \
            --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '.packages[$pkg][$ver] = {
             pkgdesc: $desc,
             upstream_author: $author,
             maintainer: $maintainer,
             categories: $categories,
             license: $lic,
             url: $url,
             status: $status,
             os_min: (if $os_min == "" then null else $os_min end),
             os_max: (if $os_max == "" then null else $os_max end),
             os_constraints: (if $os_constraints == [] then null else $os_constraints end),
             devices: $devices,
             depends: $deps,
             conflicts: $conflicts,
             provides: $provides,
             arch: [$arch],
             modifies_system: $modifies_system,
             auto_install: (if $install_if_val == "" or $install_if_val == "_" then false else true end),
             released: $now,
             _origin: (if $origin == "" or $origin == "_" then null else $origin end),
             readmeurl: (if $readmeurl == "" then null else $readmeurl end),
             donateurl: (if $donateurl == "" then null else $donateurl end)
           }' "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"
    fi

    echo "Processed: $pkg $ver ($arch)"
done 3<"$WORKDIR/all-packages.tsv"

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
' "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"

# Compute parent package devices from subpackages
# If a package has subpackages (other packages with _origin pointing to it),
# the parent's devices should be the union of all subpackage devices
echo "Computing parent package devices from subpackages..."
jq '
  # Build map of parent -> [subpackage devices]
  ([.packages | to_entries[] | .key as $pkg | .value | to_entries[] |
    select(.value._origin != null and .value._origin != $pkg) |
    {parent: .value._origin, version: .key, devices: .value.devices}
  ] | group_by(.parent) | map({
    key: .[0].parent,
    value: (map(.devices) | add | unique)
  }) | from_entries) as $parent_devices |

  # Update parent packages with computed devices
  .packages |= with_entries(
    .key as $pkg |
    if $parent_devices[$pkg] then
      .value |= with_entries(
        .value.devices = $parent_devices[$pkg]
      )
    else . end
  )
' "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"

# Remove temporary _origin field from output
jq '
  .packages |= with_entries(
    .value |= with_entries(
      .value |= del(._origin)
    )
  )
' "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"

# Preserve release timestamps from old metadata
echo "Preserving release timestamps from previous metadata..."
jq -s '
  .[0] as $old | .[1] |
  .packages |= with_entries(
    .key as $pkg |
    .value |= with_entries(
      .key as $ver |
      if $old.packages[$pkg][$ver].released then
        .value.released = $old.packages[$pkg][$ver].released
      else . end
    )
  )
' "$WORKDIR/old-metadata.json" "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"

jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.generated = $ts' "$METADATA_FILE" >tmp.json && mv tmp.json "$METADATA_FILE"

echo "Generated $METADATA_FILE"
