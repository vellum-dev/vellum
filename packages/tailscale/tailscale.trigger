#!/bin/sh

echo "reloading systemd daemon..."
systemctl daemon-reload

echo "enabling tailscaled service..."
systemctl enable tailscaled.service

echo "restarting tailscaled service..."
systemctl restart tailscaled.service
