# Huly agent connection

Codex has a global MCP entry named `huly` that runs [`huly-mcp.sh`](huly-mcp.sh). The launcher targets the bootstrap Huly URL and `Homelab` workspace and reads its token from the macOS Keychain item `homelab-huly-mcp`. The token is not stored in this repository or Codex config. The MCP package is pinned to `@firfi/huly-mcp@0.52.4`.

The current token was supplied for setup testing and should be rotated. After creating a replacement token in Huly, store it in Keychain from a local terminal:

```sh
read -s 'huly_new_token?New Huly token: '
security add-generic-password -a "$USER" -s homelab-huly-mcp -w "$huly_new_token" -U
unset huly_new_token
```

Restart Codex after changing the token. Run `codex mcp list` to confirm the `huly` entry is enabled. The Huly server must be reachable from the machine running Codex. The current bootstrap URL is HTTP on the management LAN; update `HULY_URL` in the launcher when Huly moves to the cluster or gains a hostname and TLS.

Project instructions are in [`../../AGENTS.md`](../../AGENTS.md). The Tracker project is `HOMEL`. Task, Story, Spike, and Bug are Classic Tracker task types with the five existing workflow statuses. Huly Tracker milestones and Cards Types remain separate from Tracker issue task types.
