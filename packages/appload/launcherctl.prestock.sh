#!/bin/bash
set -e
umount_q() {
  while grep -q " $1 " /proc/mounts; do
    umount -q "$1"
  done
}
umount_q /usr/lib/systemd/system/xochitl.service.d
umount_q /usr/lib/systemd/system/xochitl.service
rm -f /tmp/launcherctl-xochitl.service
