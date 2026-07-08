#!/bin/bash
cat << EOF > "/etc/systemd/system/xochitl.service.d/launcherctl-failure.conf"
[Unit]
OnFailure=launcherctl-failure.service
EOF
systemctl daemon-reload
