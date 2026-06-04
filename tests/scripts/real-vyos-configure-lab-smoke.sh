#!/usr/bin/env bash
set -euo pipefail

# Manual real-VyOS configure smoke helper.
#
# This script is intentionally lab-only. It does not start the agent and it does
# not belong in normal CI. Run it only after a vyos-nats-agent binary is already
# running on a disposable VyOS VM with:
#
#   agent.configure.mode: real
#
# Required environment:
#   REAL_VYOS_LAB_ACK=I_UNDERSTAND
#   NATS_URL=nats://<nats-host>:4222
#   PAYLOAD_FILE=/path/to/desired-config.json
#
# Optional environment:
#   TARGET=vyos
#   CONFIG_UUID=cfg-lab-$(date +%s)
#   RPC_ID=real-vyos-lab-$(date +%s)
#   TIMEOUT=90s
#   PRINT_LOGS_ON_PASS=true
#
# Example:
#   REAL_VYOS_LAB_ACK=I_UNDERSTAND \
#   NATS_URL=nats://192.0.2.10:4222 \
#   PAYLOAD_FILE=./lab/desired-vyos-wan-only-config.json \
#   ./tests/scripts/real-vyos-configure-lab-smoke.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

REAL_VYOS_LAB_ACK="${REAL_VYOS_LAB_ACK:-}"
NATS_URL="${NATS_URL:-}"
PAYLOAD_FILE="${PAYLOAD_FILE:-}"
TARGET="${TARGET:-vyos}"
CONFIG_UUID="${CONFIG_UUID:-cfg-lab-$(date +%s)}"
RPC_ID="${RPC_ID:-real-vyos-lab-$(date +%s)}"
TIMEOUT="${TIMEOUT:-90s}"
PRINT_LOGS_ON_PASS="${PRINT_LOGS_ON_PASS:-false}"

mkdir -p "${ROOT_DIR}/.tmp"
WORK_DIR="$(mktemp -d "${ROOT_DIR}/.tmp/vyos-nats-agent-real-lab-XXXXXX")"
TMP_CONFIG="${WORK_DIR}/controller-config.yaml"
CONTROLLER_DIR="${WORK_DIR}/controller"
CONTROLLER_LOG="${WORK_DIR}/controller.log"

cleanup() {
  if [[ "${KEEP_SMOKE_ARTIFACTS:-false}" != "true" ]]; then
    rm -rf "${WORK_DIR}"
  else
    echo "[INFO] kept lab smoke artifacts at ${WORK_DIR}"
  fi
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  echo "" >&2
  echo "---- controller log ----" >&2
  [[ -f "${CONTROLLER_LOG}" ]] && tail -n 260 "${CONTROLLER_LOG}" >&2 || true
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required command not found: $1"
  fi
}

if [[ "${REAL_VYOS_LAB_ACK}" != "I_UNDERSTAND" ]]; then
  fail "refusing to run real VyOS apply smoke without REAL_VYOS_LAB_ACK=I_UNDERSTAND"
fi
if [[ -z "${NATS_URL}" ]]; then
  fail "NATS_URL is required"
fi
if [[ -z "${PAYLOAD_FILE}" ]]; then
  fail "PAYLOAD_FILE is required"
fi
if [[ ! -f "${PAYLOAD_FILE}" ]]; then
  fail "PAYLOAD_FILE not found: ${PAYLOAD_FILE}"
fi

require_cmd go

echo "[INFO] preparing controller config at ${TMP_CONFIG}"
sed \
  -e "s#nats://127.0.0.1:4222#${NATS_URL}#g" \
  -e "s#target: vyos#target: ${TARGET}#g" \
  config.example.yaml > "${TMP_CONFIG}"

mkdir -p "${CONTROLLER_DIR}"

cat > "${CONTROLLER_DIR}/main.go" <<'GO'
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/routerarchitects/nats-agent-core/agentcore"
	"github.com/routerarchitects/olg-server-vyos-client-natagent/internal/config"
)

const wireVersion = "1.0"

func main() {
	var configPath string
	var payloadPath string
	var rpcID string
	var configUUID string
	var timeout time.Duration

	flag.StringVar(&configPath, "config", "", "Path to controller YAML config")
	flag.StringVar(&payloadPath, "payload", "", "Path to desired config JSON payload")
	flag.StringVar(&rpcID, "rpc-id", "", "RPC ID")
	flag.StringVar(&configUUID, "uuid", "", "Desired config UUID")
	flag.DurationVar(&timeout, "timeout", 90*time.Second, "Timeout")
	flag.Parse()

	if configPath == "" || payloadPath == "" || rpcID == "" || configUUID == "" {
		fatalf("missing required flags")
	}

	payload, err := os.ReadFile(payloadPath)
	if err != nil {
		fatalf("read payload: %v", err)
	}
	if !json.Valid(payload) {
		fatalf("payload is not valid JSON")
	}

	appCfg, err := config.Load(configPath)
	if err != nil {
		fatalf("load config: %v", err)
	}
	coreCfg, err := appCfg.ToAgentCoreConfig()
	if err != nil {
		fatalf("convert config: %v", err)
	}
	coreCfg.AgentName = "vyos-nats-agent-real-lab-controller"
	coreCfg.NATS.ClientName = "vyos-nats-agent-real-lab-controller"

	client, err := agentcore.New(coreCfg)
	if err != nil {
		fatalf("create agentcore client: %v", err)
	}

	target := appCfg.Agent.Target
	statusCh := make(chan agentcore.StatusEnvelope, 64)
	resultCh := make(chan agentcore.ResultEnvelope, 16)

	if err := client.RegisterStatusHandler(target, func(ctx context.Context, msg agentcore.StatusEnvelope) error {
		fmt.Printf("[CONTROLLER] status target=%s rpc_id=%s uuid=%s status=%s stage=%s message=%q\n",
			msg.Target, msg.RPCID, msg.UUID, msg.Status, msg.Stage, msg.Message)
		select {
		case statusCh <- msg:
		default:
		}
		return nil
	}); err != nil {
		fatalf("register status handler: %v", err)
	}

	if err := client.RegisterResultHandler(target, func(ctx context.Context, msg agentcore.ResultEnvelope) error {
		fmt.Printf("[CONTROLLER] result target=%s rpc_id=%s uuid=%s result=%s error_code=%s message=%q\n",
			msg.Target, msg.RPCID, msg.UUID, msg.Result, msg.ErrorCode, msg.Message)
		select {
		case resultCh <- msg:
		default:
		}
		return nil
	}); err != nil {
		fatalf("register result handler: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	if err := client.Start(ctx); err != nil {
		fatalf("start controller client: %v", err)
	}
	defer func() {
		closeCtx, closeCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer closeCancel()
		if err := client.Close(closeCtx); err != nil {
			fmt.Fprintf(os.Stderr, "[CONTROLLER] close client: %v\n", err)
		}
	}()

	fmt.Printf("[CONTROLLER] desired payload before KV submit target=%s rpc_id=%s uuid=%s payload_json=%s\n",
		target, rpcID, configUUID, string(payload))

	ack, err := client.SubmitConfigure(ctx, agentcore.ConfigureCommand{
		Version:   wireVersion,
		RPCID:     rpcID,
		Target:    target,
		UUID:      configUUID,
		Payload:   json.RawMessage(payload),
		Timestamp: time.Now().UTC(),
	})
	if err != nil {
		fatalf("submit configure: %v", err)
	}
	fmt.Printf("[CONTROLLER] submitted configure to KV accepted=%v rpc_id=%s uuid=%s kv_bucket=%s kv_key=%s kv_revision=%d\n",
		ack.Accepted, rpcID, configUUID, ack.KVBucket, ack.KVKey, ack.KVRevision)

	for {
		select {
		case <-ctx.Done():
			fatalf("timed out waiting for configure result rpc_id=%s uuid=%s: %v", rpcID, configUUID, ctx.Err())
		case msg := <-statusCh:
			if msg.RPCID == rpcID && msg.UUID == configUUID && msg.Status == "failure" {
				fatalf("agent reported failure status at stage=%s message=%q", msg.Stage, msg.Message)
			}
		case msg := <-resultCh:
			if msg.RPCID != rpcID || msg.UUID != configUUID || msg.CommandType != "configure" {
				continue
			}
			if msg.Result != "success" {
				fatalf("configure failed: error_code=%s message=%q", msg.ErrorCode, msg.Message)
			}
			fmt.Printf("[CONTROLLER] configure success rpc_id=%s uuid=%s message=%q\n", msg.RPCID, msg.UUID, msg.Message)
			return
		}
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[CONTROLLER][FAIL] "+format+"\n", args...)
	os.Exit(1)
}
GO

echo "[INFO] submitting real configure to target=${TARGET} rpc_id=${RPC_ID} uuid=${CONFIG_UUID}"
if ! go run "${CONTROLLER_DIR}" \
  --config "${TMP_CONFIG}" \
  --payload "${PAYLOAD_FILE}" \
  --rpc-id "${RPC_ID}" \
  --uuid "${CONFIG_UUID}" \
  --timeout "${TIMEOUT}" >"${CONTROLLER_LOG}" 2>&1; then
  fail "real VyOS lab configure smoke failed"
fi

echo "[PASS] Real VyOS lab configure smoke passed"

if [[ "${PRINT_LOGS_ON_PASS}" == "true" ]]; then
  echo ""
  echo "---- controller log ----"
  tail -n 260 "${CONTROLLER_LOG}" || true
fi
