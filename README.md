# AI Ops MCP Client

Connects Claude Desktop on your Mac to the AI Ops MCP server running on ECS, so Claude can inspect and operate the EKS workload. This folder does not deploy or modify the MCP server.

## Architecture

```text
Claude Desktop -> mcp-remote (local stdio bridge) -> http://<alb>:8080/mcp -> ECS MCP server -> EKS
```

Claude Desktop launches MCP servers as local commands, so the remote Streamable HTTP server is reached through [`mcp-remote`](https://www.npmjs.com/package/mcp-remote), started with `npx`.

The current server exposes `get_pods`, `get_pod_logs`, `get_events`, `describe_pod`, `describe_deployment`, `describe_service`, `scale_deployment`, and `restart_pod`. Its namespace allowlist is `application`; it has no dedicated cluster-wide health tool and will reject `payments` unless the server permits it.

## Workshop Deploy Order

```bash
../mcp-server-deployments/deploy.sh <version>   # 1. build + push the MCP image to ECR
../mcp-server-terraform/deploy.sh               # 2. VPC, EKS, ECS, ALB + nginx workload
./deploy.sh                                     # 3. this folder: verify the server, configure Claude Desktop
```

## Prerequisites

- macOS with Claude Desktop installed.
- Terraform, `curl`, and `python3`.
- Node.js 18+ with `npx` (`brew install node` or https://nodejs.org).
- Your public IP listed in `public_allowed_cidrs` in `../mcp-server-terraform/terraform.tfvars`, applied with Terraform. The ALB rejects everyone else.

## Deploy

Quit Claude Desktop completely (Cmd+Q) first. While it is running, Claude Desktop rewrites its config file from memory and drops any entry added from outside, so the script refuses to run until it is closed.

```bash
./deploy.sh
```

The script:

1. Checks the local prerequisites above and that Claude Desktop is not running.
2. Reads `internal_mcp_url` from the `mcp-server-terraform` outputs.
3. Warns if your public IP is not in `public_allowed_cidrs`.
4. Waits for `/health` on the ALB to respond (up to 300 seconds).
5. Runs an MCP handshake and lists the server's tools.
6. Pre-fetches `mcp-remote` into the npm cache.
7. Adds an `aiops-eks` entry (absolute `npx` path, with node's directory on `PATH`) to `~/Library/Application Support/Claude/claude_desktop_config.json`, preserving other MCP servers and saving the previous file as `claude_desktop_config.json.bak`.

Then open Claude Desktop. In a new chat, the tools menu under the message box should list `aiops-eks` and its tools. Try: "List the pods in the application namespace."

Optional overrides:

| Variable | Default |
| --- | --- |
| `MCP_SERVER_URL` | `internal_mcp_url` Terraform output |
| `MCP_TERRAFORM_DIR` | `../mcp-server-terraform` |
| `HEALTH_TIMEOUT_SECONDS` | `300` |
| `CLAUDE_CONFIG_PATH` | `~/Library/Application Support/Claude/claude_desktop_config.json` |

## Manual Configuration

`claude_desktop_config.json.example` shows the entry the script writes. To set it up by hand, replace `<alb-dns-name>` with the ALB hostname and merge it into your Claude Desktop config. Quit Claude Desktop before editing the file. Claude Desktop does not load your shell `PATH`, so set `command` to the absolute `npx` path (`command -v npx`) and set `env.PATH` to start with node's directory (`dirname "$(command -v node)"`): `npx` starts with `#!/usr/bin/env node` and fails without it. This matters most with nvm, which only adds node to `PATH` in your shell. `--allow-http` is required because the ALB listener is plain HTTP on port `8080`.

## Troubleshooting

- `/health` gets no response (HTTP `000`): the ALB security group is blocking your IP. Update `public_allowed_cidrs` and re-run `terraform apply`.
- HTTP `502`/`503`/`504`: the ALB has no healthy ECS task. Check the ECS service and CloudWatch logs `/ecs/<project>-<env>`.
- HTTP `421`: the ALB hostname is missing from `MCP_ALLOWED_HOSTS` on the server.
- HTTP `404`: the URL must end in `/mcp`.
- `aiops-eks` does not appear in Claude Desktop: check `tail -n 50 ~/Library/Logs/Claude/mcp-server-aiops-eks.log`.
- `aiops-eks` does not appear and that log file doesn't exist: the entry is missing from `claude_desktop_config.json`. Claude Desktop was probably open when the entry was written and saved over it. Quit Claude Desktop (Cmd+Q), re-run `./deploy.sh`, then open it.
- `env: node: No such file or directory` in the log: Claude Desktop cannot find `node`. Make sure the entry's `env.PATH` starts with node's directory, or re-run `./deploy.sh`. If you switch Node versions with nvm, re-run the script so the paths match.
- Namespace errors: the server currently allows `application`; it does not authorize `payments`.
- No cluster-wide health result: the server does not advertise a `get_cluster_health` tool.
