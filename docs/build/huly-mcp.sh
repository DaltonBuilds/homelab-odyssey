#!/bin/sh
set -eu

export HULY_URL='http://192.168.40.158'
export HULY_WORKSPACE='e44b5e8c-8258-4e65-ba92-1b1860b63b2c'
export HULY_TOKEN="$(security find-generic-password -a "$USER" -s homelab-huly-mcp -w)"
export TOOLSETS='issues,projects,milestones,task-management,search'

exec npx -y @firfi/huly-mcp@0.52.4
