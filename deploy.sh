#!/usr/bin/env bash
# Step 3 of the workshop deploy: verify the MCP server and connect Claude Desktop to it.
#
#   1. ../mcp-server-deployments/deploy.sh <version>   build + push the MCP image to ECR
#   2. ../mcp-server-terraform/deploy.sh               VPC, EKS, ECS, ALB + nginx workload
#   3. ./deploy.sh                                     this script
#
# Claude Desktop -> mcp-remote (local stdio bridge) -> http://<alb>:8080/mcp -> ECS -> EKS
# /mcp requires a bearer token, read from the SSM parameter in the Terraform output mcp_auth_token_parameter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${MCP_TERRAFORM_DIR:-$SCRIPT_DIR/../mcp-server-terraform}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-300}"
# Windows (Git Bash) keeps the Claude Desktop config under %APPDATA%; everything else uses the macOS path.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows; DEFAULT_CLAUDE_CONFIG="$APPDATA/Claude/claude_desktop_config.json" ;;
  *)                    PLATFORM=macos;   DEFAULT_CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
esac
CLAUDE_CONFIG_PATH="${CLAUDE_CONFIG_PATH:-$DEFAULT_CLAUDE_CONFIG}"

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK  %s\n' "$*"; }
warn() { printf '    WARN %s\n' "$*" >&2; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

step "Checking local prerequisites"
for cmd in terraform aws curl python3 node npx; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd is required (node/npx: https://nodejs.org or 'brew install node')"
done
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[[ "$NODE_MAJOR" -ge 18 ]] || fail "Node.js 18+ is required, found $(node -v)"
ok "terraform, aws, curl, python3, node $(node -v), npx"

# Claude Desktop rewrites its config file from memory while it runs, which would drop our entry.
if [[ "$PLATFORM" == windows ]]; then
  if tasklist //FI "IMAGENAME eq Claude.exe" 2>/dev/null | grep -i 'claude\.exe' >/dev/null; then
    fail "Claude Desktop is running. Quit it from the system tray (right-click > Quit), then re-run ./deploy.sh."
  fi
elif ps -axo comm= | grep '/Claude\.app/Contents/MacOS/Claude$' >/dev/null; then
  fail "Claude Desktop is running. Quit it completely (Cmd+Q), then re-run ./deploy.sh."
fi
ok "Claude Desktop is not running"

step "Reading the MCP endpoint from Terraform outputs"
MCP_SERVER_URL="${MCP_SERVER_URL:-$(terraform -chdir="$TERRAFORM_DIR" output -raw internal_mcp_url 2>/dev/null || true)}"
[[ -n "$MCP_SERVER_URL" ]] || fail "could not read internal_mcp_url from $TERRAFORM_DIR. Run ../mcp-server-terraform/deploy.sh first."
BASE_URL="${MCP_SERVER_URL%/mcp}"
ok "$MCP_SERVER_URL"

step "Reading the MCP bearer token"
if [[ -n "${MCP_AUTH_TOKEN:-}" ]]; then
  ok "using MCP_AUTH_TOKEN from the environment"
else
  TOKEN_PARAM="$(terraform -chdir="$TERRAFORM_DIR" output -raw mcp_auth_token_parameter 2>/dev/null || true)"
  [[ -n "$TOKEN_PARAM" ]] || fail "could not read mcp_auth_token_parameter from $TERRAFORM_DIR. Run ../mcp-server-terraform/deploy.sh first."
  MCP_AUTH_TOKEN="$(aws ssm get-parameter --name "$TOKEN_PARAM" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)"
  [[ -n "$MCP_AUTH_TOKEN" && "$MCP_AUTH_TOKEN" != "None" ]] || fail "could not read the token from SSM parameter $TOKEN_PARAM. Check your AWS credentials, or run ../mcp-server-terraform/deploy.sh first."
  ok "read from SSM parameter $TOKEN_PARAM"
fi
# Passed to the Python steps through the environment, never on a command line or in output.
export MCP_AUTH_TOKEN

step "Checking your public IP against the ALB allow-list"
MY_IP="$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]' || true)"
ALLOWED="$(awk -F'=' '/^public_allowed_cidrs/ {print $2}' "$TERRAFORM_DIR/terraform.tfvars" 2>/dev/null | tr -d ' []"' || true)"
if [[ -z "$MY_IP" ]]; then
  warn "could not determine your public IP; skipping this check"
elif [[ ",$ALLOWED," == *",$MY_IP/32,"* ]]; then
  ok "$MY_IP is allowed"
else
  warn "your IP $MY_IP is not in public_allowed_cidrs ($ALLOWED)."
  warn "Update public_allowed_cidrs in $TERRAFORM_DIR/terraform.tfvars and re-run terraform apply, or the next step will time out."
fi

step "Waiting for $BASE_URL/health (up to ${HEALTH_TIMEOUT_SECONDS}s)"
deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
until curl -fsS --max-time 5 "$BASE_URL/health" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE_URL/health" || true)"
    case "$code" in
      000) fail "no response: the ALB security group is probably blocking your IP (see the warning above)" ;;
      502|503|504) fail "HTTP $code: the ALB has no healthy ECS task. Check the ECS service and CloudWatch logs /ecs/<project>-<env>" ;;
      *) fail "HTTP $code from /health" ;;
    esac
  fi
  printf '    waiting...\n'
  sleep 10
done
ok "$(curl -fsS --max-time 5 "$BASE_URL/health")"

step "Running an MCP handshake and listing tools"
python3 - "$MCP_SERVER_URL" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

url = sys.argv[1]
headers = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "Authorization": f"Bearer {os.environ['MCP_AUTH_TOKEN']}",
}


def call(payload, session_id=None):
    h = dict(headers)
    if session_id:
        h["mcp-session-id"] = session_id
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode()
            sid = resp.headers.get("mcp-session-id")
    except urllib.error.HTTPError as exc:
        hint = {401: "token rejected: re-run after terraform apply, or check MCP_AUTH_TOKEN",
                421: "Host header rejected: the ALB hostname is missing from MCP_ALLOWED_HOSTS",
                404: "wrong path: the URL must end in /mcp"}.get(exc.code, "")
        sys.exit(f"    FAIL HTTP {exc.code} from {url} {hint}")
    if not body.strip():
        return None, sid
    # Streamable HTTP answers with plain JSON or a server-sent-events stream.
    if body.lstrip().startswith("{"):
        return json.loads(body), sid
    for line in body.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:].strip()), sid
    sys.exit(f"    FAIL unexpected response: {body[:200]}")


init, session_id = call({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-03-26", "capabilities": {},
               "clientInfo": {"name": "workshop-deploy", "version": "0"}},
})
server = init.get("result", {}).get("serverInfo", {})
print(f"    OK  connected to {server.get('name')} {server.get('version', '')}".rstrip())

call({"jsonrpc": "2.0", "method": "notifications/initialized"}, session_id)
tools, _ = call({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, session_id)
names = [t["name"] for t in tools.get("result", {}).get("tools", [])]
print(f"    OK  {len(names)} tools: {', '.join(names)}")
if not names:
    sys.exit("    FAIL the server advertised no tools")
PY

step "Pre-fetching mcp-remote so Claude Desktop starts it quickly"
npm cache add mcp-remote >/dev/null 2>&1 && ok "mcp-remote cached" || warn "could not pre-fetch mcp-remote; Claude Desktop will download it on first start"

step "Writing the Claude Desktop configuration"
# Claude Desktop launches local commands, so the remote HTTP server is reached through the
# mcp-remote stdio bridge. Claude Desktop doesn't load your shell PATH, so use the absolute npx
# path and put node's directory on PATH for it: npx starts with `#!/usr/bin/env node`.
# The token goes in env.AUTH_HEADER; mcp-remote expands ${AUTH_HEADER} in its --header argument.
# On Windows, Claude Desktop starts npx through `cmd /c`, which finds npx on the Windows PATH.
python3 - "$CLAUDE_CONFIG_PATH" "$MCP_SERVER_URL" "$(command -v npx)" "$(dirname "$(command -v node)")" "$PLATFORM" <<'PY'
import json
import os
import pathlib
import shutil
import sys

config_path = pathlib.Path(sys.argv[1])
server_url = sys.argv[2]
npx_path = sys.argv[3]
node_dir = sys.argv[4]
platform = sys.argv[5]
config_path.parent.mkdir(parents=True, exist_ok=True)

if config_path.exists():
    shutil.copy2(config_path, config_path.with_suffix(".json.bak"))
    config = json.loads(config_path.read_text())
else:
    config = {}

servers = config.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    raise SystemExit("    FAIL Claude config must contain an object named mcpServers")

args = ["-y", "mcp-remote", server_url]
if server_url.startswith("http://"):
    # mcp-remote refuses plain HTTP to anything but localhost without this flag.
    args.append("--allow-http")
# No space after the colon: Claude Desktop splits args with spaces on some platforms.
args += ["--header", "Authorization:${AUTH_HEADER}"]

if platform == "windows":
    servers["aiops-eks"] = {
        "command": "cmd",
        "args": ["/c", "npx"] + args,
        "env": {"AUTH_HEADER": f"Bearer {os.environ['MCP_AUTH_TOKEN']}"},
    }
else:
    servers["aiops-eks"] = {
        "command": npx_path,
        "args": args,
        "env": {
            "PATH": f"{node_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "AUTH_HEADER": f"Bearer {os.environ['MCP_AUTH_TOKEN']}",
        },
    }
config_path.write_text(json.dumps(config, indent=2) + "\n")
print(f"    OK  wrote aiops-eks to {config_path} (previous version saved as .json.bak)")
print("    The config file now contains the MCP bearer token; don't share it.")
PY

if [[ "$PLATFORM" == windows ]]; then
  CLAUDE_LOG='%APPDATA%\Claude\logs\mcp-server-aiops-eks.log'
else
  CLAUDE_LOG='tail -n 50 ~/Library/Logs/Claude/mcp-server-aiops-eks.log'
fi

cat <<EOF

==> Done. Last steps in Claude Desktop:
    1. Open Claude Desktop.
    2. In a new chat, open the tools menu under the message box: "aiops-eks" should list the tools above.
    3. Try: "List the pods in the application namespace."

    If aiops-eks doesn't appear, check:
      $CLAUDE_LOG
EOF
