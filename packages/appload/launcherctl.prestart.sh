#!/bin/bash
set -e
umount_q() {
  while grep -q " $1 " /proc/mounts; do
    umount -q "$1"
  done
}
target_dir=/usr/lib/systemd/system/xochitl.service.d
umount_q "$target_dir"
if [ -d "$target_dir" ]; then
  temp="$(mktemp -d)"
  cp -a "$target_dir"/. "$temp"/
  sed -i 's|^OnFailure=.*$||' "$temp"/*
  mount -t tmpfs tmpfs "$target_dir"
  cp -a "$temp"/. "$target_dir"/
  rm -r "$temp"
else
  mount -t tmpfs tmpfs "$target_dir"
fi
cat <<EOF >"$target_dir/99-launcherctl-failure.conf"
[Unit]
OnFailure=launcherctl-failure.service
EOF
sed 's|^OnFailure=.*$||' /usr/lib/systemd/system/xochitl.service >/tmp/launcherctl-xochitl.service
mount -o bind /tmp/launcherctl-xochitl.service /usr/lib/systemd/system/xochitl.service
systemctl daemon-reload
