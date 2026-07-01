# VyOS NATS Agent Test Guide

This guide provides step-by-step instructions to run, verify, and inspect logs for all test categories in the `TIP-olg-server-vyos-client-natsagent` repository.

---

## 1. Unit Tests

**Objective**: Verify isolated package component logic (actions, validation, configuration, state store).

### Execution Command
Run all unit tests in the repository:
```bash
go test -v ./internal/...
```

To run only the unit tests inside a specific package (e.g., `configure`):
```bash
go test -v ./internal/configure/
```

### Inspecting Logs
* Results and errors print directly to the terminal stdout/stderr.
* Look for individual package pass/fail outcomes.

---

## 2. Integration Tests

**Objective**: Verify end-to-end NATS JetStream interactions, configure and action flows, status/result publishing, and agent startup/reconnect behaviors against a real `nats-server` running locally.

### Execution Command
Run all integration tests (requires a local `nats-server` binary to be available in your PATH):
```bash
go test -tags=integration -v ./tests/integration/...
```

To run only a specific integration test (e.g., reconnection or startup reconciliation):
```bash
# Reconnection Reconcile Integration Test
go test -tags=integration -v ./tests/integration/... -run TestIntegrationReconnectReconcile

# Startup Reconcile Integration Test
go test -tags=integration -v ./tests/integration/... -run TestIntegrationStartupReconcile

# Startup Reconcile Failure Test
go test -tags=integration -v ./tests/integration/... -run TestIntegrationStartupReconcileFailure
```

### Inspecting Logs
* All connection events, subscription states, and logging outputs from the simulated runtime print directly to the console.

---

## 3. Smoke Tests (Local NATS-Only, Mock Platform)

**Objective**: Verify the agent's NATS subscription/KV configuration and action workflows using a compiled agent binary against a local NATS server, without requiring a real VyOS machine.

### Execution Commands
* **Configure Smoke Test**:
  ```bash
  ./tests/smoke/real-nats-configure-smoke.sh
  ```
* **Action Smoke Test**:
  ```bash
  ./tests/smoke/real-nats-action-smoke.sh
  ```

### Inspecting Logs
* These scripts spin up temporary local NATS servers and output runtime artifacts into local directories.
* Inspect terminal output or navigate to the directory printed at the end of the test execution (usually under `/tmp/vyos-nats-agent-smoke-*`) to view agent, controller, and NATS logs.

---

## 4. Real Lab Tests (Real NATS, Real VyOS VM)

**Objective**: Validate actual VyOS configuration injection, local state checkpointing, and real diagnostic flows (packet capturing via `tcpdump` and multipart HTTP upload) on a target VyOS VM.

### Step 4.1: Build for VyOS VM Target
On your local development machine, compile the binary for the VyOS Linux x86_64 architecture:
```bash
GOOS=linux GOARCH=amd64 go build -o vyos-nats-agent ./cmd/vyos-nats-agent
```

### Step 4.2: Copy Binary and Config to VyOS VM
Upload the binary and configuration template to your VyOS VM using `scp`:
```bash
scp vyos-nats-agent config.example.yaml vyos@<vyos-vm-ip>:/home/vyos/
```

### Step 4.3: Setup and Deploy on the VyOS VM
1. SSH into the VyOS VM:
   ```bash
   ssh vyos@<vyos-vm-ip>
   ```
2. Stop any existing running agent instances:
   ```bash
   sudo pkill vyos-nats-agent
   ps aux | grep vyos-nats-agent
   ```
3. Copy the uploaded config template into `vyos-nats-agent.yaml`:
   ```bash
   cp config.example.yaml ~/vyos-nats-agent.yaml
   ```
4. Edit `~/vyos-nats-agent.yaml` to match the exact working configuration:
   ```yaml
   agent:
     target: vyos
     state_file: /tmp/vyos-nats-agent/state.json

     logging:
       enabled: true
       level: debug
       format: text

     actions:
       mode: real
       enabled:
         - trace

     configure:
       mode: real

     debug:
       log_payloads: true
       log_rendered: true
       log_apply_plan: true

     apply:
       save_after_commit: false

   agentcore:
     nats:
       servers:
         - nats://192.168.76.69:4222

     kv:
       bucket: cfg_desired
       auto_create_bucket: true

     timeouts:
       kv_timeout: 1s
   ```
5. Install the binary to the system path and launch it in the background using `nohup`:
   ```bash
   sudo install -m 0755 ~/vyos-nats-agent /usr/local/bin/vyos-nats-agent
   nohup /usr/local/bin/vyos-nats-agent --config ~/vyos-nats-agent.yaml >/tmp/vyos-nats-agent.log 2>&1 &
   ```

### Step 4.4: Export Controller Host Environment Variables
On your controller host (or local development machine), export the required credentials:
```bash
export REAL_VYOS_LAB_ACK=I_UNDERSTAND
export NATS_URL=nats://192.168.76.69:4222
export VYOS_TARGET=vyos
export VYOS_HOST=192.168.76.2
export VYOS_USER=vyos
export VYOS_PASSWORD=vyos
export STATE_PATH=/tmp/vyos-nats-agent/state.json
export REMOTE_AGENT_LOG=/tmp/vyos-nats-agent.log
export DESIRED_CONFIG_FILE=tests/lab/configs/desired-vyos-wan-only-config.json
export ARTIFACT_DIR=tests/lab/artifacts/manual-run-001
export VYOS_SHOW_CONFIG_COMMAND="/opt/vyatta/bin/vyatta-op-cmd-wrapper show configuration commands"
```

### Step 4.5: Execute Configure Smoke
Verify NATS KV-to-VyOS command rendering and applying pipelines:
```bash
./tests/lab/real-vyos-configure-smoke.sh
```

### Step 4.6: Execute Action Trace Smoke
Verify the packet capture command and multipart HTTP upload:
```bash
./tests/lab/real-vyos-action-trace-smoke.sh
```

### Step 4.7: Inspect Artifacts & Logs
Navigate to your `ARTIFACT_DIR` (e.g., `tests/lab/artifacts/manual-run-001/`) to inspect the diagnostics:
* **Controller Logs (`controller.log`)**: Verify command submission, HTTP server upload receipt, and responses.
* **Agent Logs (`agent.log`)**: Copied automatically from the remote VyOS host's `/tmp/vyos-nats-agent.log` path.
* **PCAP Captures (`captured.pcap`)**: Inspect the captured packet trace using `tcpdump -r captured.pcap` or Wireshark.
* **State Checkpoints (`state.json`)**: Verifies the local target state on the VyOS router matches the expected applied UUID.
* **Status & Result Logs**: Check `configure-status.jsonl` / `configure-result.jsonl` for configuration trials, or `action-status.jsonl` / `action-result.jsonl` for trace actions.

---

## 5. Lab Validation Scenarios (Real VyOS VM)

Perform the following manual steps on the VyOS VM to validate the 7 core reconciliation behaviors.

### 5.1 Config Drift on Startup (Automatic Application on Boot)
* **Setup**: Delete the local `/tmp/vyos-nats-agent/state.json` file. Put a desired configuration in NATS KV (UUID `cfg-drift-001`).
* **Execution**: Start the agent on the VyOS VM:
  ```bash
  sudo pkill vyos-nats-agent
  nohup /usr/local/bin/vyos-nats-agent --config ~/vyos-nats-agent.yaml >/tmp/vyos-nats-agent.log 2>&1 &
  ```
* **Expected Result**: 
  - Log `tail -f /tmp/vyos-nats-agent.log` shows: `reconcile: configuration drift detected, applying config ... desired_uuid=cfg-drift-001`.
  - The configuration commands are rendered, applied, and the log states `configure state saved`.
  - `/tmp/vyos-nats-agent/state.json` contains `"applied_uuid": "cfg-drift-001"`.

### 5.2 Already-in-Sync
* **Setup**: Keep `/tmp/vyos-nats-agent/state.json` matching the KV desired config (UUID `cfg-drift-001`).
* **Execution**: Start the agent on the VyOS VM.
* **Expected Result**: Logs show `reconcile: already in sync` and the agent starts instantly without running any VyOS commands.

### 5.3 No Desired Config
* **Setup**: Delete the target's desired config key from NATS KV:
  ```bash
  nats kv del cfg_desired desired.vyos
  ```
* **Execution**: Start the agent on the VyOS VM.
* **Expected Result**: Logs show `reconcile: no desired config exists, continuing normally`. Startup completes safely.

### 5.4 Local State Corruption Recovery
* **Setup**: Write corrupted JSON (e.g., `garbage-text-{{{`) to `/tmp/vyos-nats-agent/state.json`. Seed a desired config in NATS KV.
* **Execution**: Start the agent on the VyOS VM.
* **Expected Result**: Logs show state load warning, treats it as empty state, applies the configuration, and overwrites the state file with a valid JSON file and the desired UUID.

### 5.5 Non-Fatal KV Load/Decode Failures
* **Setup**: Write invalid JSON (e.g., `invalid json {{{{`) to NATS KV under the key `desired.vyos`.
* **Execution**: Start the agent on the VyOS VM.
* **Expected Result**: Agent connects, logs `reconcile: failed to load desired config` (with a decode failure message), publishes a degraded status to NATS, and continues running safely.

### 5.6 Lightweight Configure Notification (NATS Pub Trigger)
* **Setup**: Put a new configuration UUID in NATS KV (UUID `cfg-drift-002`):
  ```bash
  nats kv put cfg_desired desired.vyos '{
    "version": "1.0",
    "rpcid": "manual-rpc-drift2",
    "target": "vyos",
    "uuid": "cfg-drift-002",
    "timestamp": "2026-06-22T13:00:00Z",
    "payload": {
      "schema_name": "olg-ucentral",
      "schema_version": "4.2.0",
      "config": {
        "uuid": 1779874987,
        "services": {
          "ssh": {
            "port": 22
          }
        },
        "interfaces": [
          {
            "name": "OLG_APPLY_SMOKE_TEST_Upstream2",
            "role": "upstream",
            "ethernet": [
              {
                "select-ports": [
                  "WAN*"
                ]
              }
            ],
            "ipv4": {
              "addressing": "dynamic"
            }
          }
        ]
      }
    }
  }'
  ```
* **Execution**: Publish the configure trigger command to the NATS command topic:
  ```bash
  nats pub cmd.configure.vyos '{
    "version": "1.0",
    "rpc_id": "manual-rpc-drift2",
    "target": "vyos",
    "command_type": "configure",
    "uuid": "cfg-drift-002",
    "kv_bucket": "cfg_desired",
    "kv_key": "desired.vyos",
    "timestamp": "2026-06-22T13:00:00Z"
  }'
  ```
* **Expected Result**: The running agent receives the message, fetches the new configuration from KV, applies it, and updates `state.json` to `"cfg-drift-002"`.

### 5.7 NATS Connection Recovery (Runtime Reconcile)
* **Setup**: Stop the NATS server on your host machine to simulate a connection drop. While NATS is offline, put a new configuration (UUID `cfg-drift-003`) into the NATS KV bucket.
* **Execution**: Restart the NATS server on your host machine.
* **Expected Result**: The running agent automatically reconnects, restores its command subscriptions, logs `reconnect detected, starting reconciliation pass`, pulls the new configuration from the NATS KV bucket, and applies it asynchronously.

---

## 6. Gaps and Out of Scope Items (Out of Scope / Gaps in Current Code)

The following items are intentionally out of scope or tracked as gaps in the current implementation:

1. **Initial Connection Retries on Boot**:
   - If the NATS server is completely offline when the agent boots, the agent fails to initialize and exits immediately. It does not perform interval reconnection retries on startup (relies on a service supervisor like `systemd` to handle restarts).
2. **Durable Command Queues**:
   - Configuration commands and actions are processed dynamically during runtime. Durable queues for buffering offline commands are not implemented.
3. **Multi-Target Concurrency Support**:
   - The agent is designed to run on a single target host (`vyos`). Running multiple targets concurrently under a single agent instance is out of scope.
