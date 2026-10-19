#!/usr/bin/env bash
set -euo pipefail
user="$(/opt/bisquite/edge/lib/get_cloud_user.sh)"
echo "$user" > /var/lib/bisquite/edge/user
