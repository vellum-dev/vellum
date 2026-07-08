#!/bin/bash
rm -f /etc/systemd/system/xochitl.service.d/launcherctl-failure.conf
systemctl daemon-reload
