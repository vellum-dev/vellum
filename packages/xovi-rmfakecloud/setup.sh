#!/bin/sh

printf "%s" "Enter your rmfakecloud hostname (e.g. example.com): "
read -r host

printf "%s" "Enter your rmfakecloud port number (leave empty for 443): "
read -r port
port=${port:-443}

mkdir -p /home/root/xovi/exthome/rmfakecloud
printf "host=%s\nport=%s\n" "$host" "$port" > /home/root/xovi/exthome/rmfakecloud/config.conf

printf "Sync URL set to %s:%s\n" "$host" "$port"
