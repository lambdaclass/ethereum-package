# Adding a new Lean consensus client to ethereum-package

This guide walks through every change you need to integrate a new Lean
consensus client (ream, zeam, qlean, lantern, grandine, lighthouse-lean,
gean, peam, nlean, or a new one). Read
[`lean-consensus.md`](./lean-consensus.md) first for the architecture.

The integration has **5 touch points**. The Lean genesis pipeline,
hash-sig key generation, P2P key allocation, and per-node IP allocation
are all generic and require no changes.

---

## Naming convention

Every Lean node is named `<client>_<index>`:

- `ethlambda_0` — first node for ethlambda
- `ethlambda_1`, `ethlambda_2` — additional nodes when `count > 1`

The Kurtosis service name is `lean-<client>_<index>` (e.g.
`lean-ethlambda_0`). The prefix before the first underscore is the **client
type** and matches `LEAN_TYPE` in `src/package_io/constants.star`.

---

## Touch point 1 — Register the client type

Add your client to `LEAN_TYPE` in `src/package_io/constants.star`:

```python
LEAN_TYPE = struct(
    ethlambda="ethlambda",
    ream="ream",
    zeam="zeam",
    # ...
    myclient="myclient",
)
```

Then add a default image to `DEFAULT_LEAN_IMAGES` in
`src/package_io/input_parser.star`:

```python
DEFAULT_LEAN_IMAGES = {
    constants.LEAN_TYPE.ethlambda: "ghcr.io/lambdaclass/ethlambda:devnet4",
    # ...
    constants.LEAN_TYPE.myclient: "ghcr.io/yourorg/myclient:devnet4",
}
```

> The default image must run as a non-interactive container with the client
> binary as its `ENTRYPOINT`. The Lean launcher overrides `entrypoint` to
> `/bin/sh -c` so it can run a `tail -f` placeholder, but during normal
> operation the original entrypoint is replaced by a constructed command
> line.

---

## Touch point 2 — `src/lean/myclient/myclient_launcher.star`

Copy `src/lean/ethlambda/ethlambda_launcher.star` and adapt the CLI surface.
You must export exactly two functions: `initialize` and `start`.

```python
"""
myclient launcher.

Translates the Lean pipeline's per-node record into myclient's CLI surface.
See [client docs/CLI reference] for the source of truth.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/usr/local/bin/myclient"
GENESIS_MOUNT = constants.LEAN_GENESIS_MOUNTPOINT_ON_CLIENTS
HASH_SIG_MOUNT = GENESIS_MOUNT + "/hash-sig-keys"
DATA_DIR = "/data"
NODE_KEY_MOUNT = constants.LEAN_NODE_KEY_MOUNTPOINT_ON_CLIENTS


def initialize(plan, node, p2p_keys_artifact):
    # Phase 1: stand the placeholder service up so Kurtosis assigns an IP.
    return plan.add_service(node["service_name"], ServiceConfig(
        image = node["image"],
        entrypoint = ["/bin/sh", "-c"],
        cmd = lean_shared.lean_tail_logs_cmd(node["service_name"])[2:],
        ports = lean_shared.lean_port_specs(),
        files = {NODE_KEY_MOUNT: p2p_keys_artifact},
        env_vars = node["extra_env_vars"],
        labels = node["extra_labels"],
        # ... (cpu/mem/node_selectors/tolerations - copy from ethlambda)
    ))


def start(plan, node, service, genesis_artifact, hash_sig_artifact):
    # Phase 3: re-add the service with full mounts and the real command.
    cmd_parts = [
        ENTRYPOINT,
        # Required - your CLI must accept these (or equivalent):
        "--genesis",   "{0}/config.yaml".format(GENESIS_MOUNT),
        "--validators","{0}/annotated_validators.yaml".format(GENESIS_MOUNT),
        "--bootnodes", "{0}/nodes.yaml".format(GENESIS_MOUNT),
        "--data-dir",  DATA_DIR,
        "--node-id",   node["node_name"],
        "--node-key",  "{0}/{1}.key".format(NODE_KEY_MOUNT, node["node_name"]),
        # Ports - your CLI must accept distinct flags for QUIC, REST, metrics:
        "--gossipsub-port", str(constants.LEAN_QUIC_PORT_NUM),
        "--api-port",       str(constants.LEAN_API_PORT_NUM),
        "--metrics-port",   str(constants.LEAN_METRICS_PORT_NUM),
        "--http-address",   "0.0.0.0",
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")
    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    log_file = lean_shared.lean_log_file_path(service.name)
    full_cmd = " ".join(cmd_parts)

    new_service = plan.add_service(
        name = service.name,
        force_update = True,
        config = ServiceConfig(
            image = node["image"],
            entrypoint = ["/bin/sh", "-c"],
            cmd = ["{0} 2>&1 | tee -a {1}".format(full_cmd, log_file)],
            ports = lean_shared.lean_port_specs(),
            files = {
                NODE_KEY_MOUNT:  node["_p2p_keys_artifact"],
                GENESIS_MOUNT:   genesis_artifact,
                HASH_SIG_MOUNT:  hash_sig_artifact,
            },
            # ... (env_vars/labels/cpu/mem/node_selectors/tolerations)
        ),
    )

    return lean_context.new_lean_context(
        client_name  = constants.LEAN_TYPE.myclient,
        service_name = new_service.name,
        ip_address   = new_service.ip_address,
        quic_port    = constants.LEAN_QUIC_PORT_NUM,
        api_port     = constants.LEAN_API_PORT_NUM,
        metrics_port = constants.LEAN_METRICS_PORT_NUM,
        api_url      = "http://{0}:{1}".format(new_service.ip_address, constants.LEAN_API_PORT_NUM),
        metrics_url  = "http://{0}:{1}/metrics".format(new_service.ip_address, constants.LEAN_METRICS_PORT_NUM),
        metrics_info = {
            "name":   new_service.name,
            "url":    "http://{0}:{1}/metrics".format(new_service.ip_address, constants.LEAN_METRICS_PORT_NUM),
            "path":   "/metrics",
            "config": node["prometheus_config"],
        },
    )
```

---

## Touch point 3 — Dispatch in `src/lean/lean_launcher.star`

Add an `import_module` for your launcher and route to it in `_launcher_for`:

```python
myclient_launcher = import_module("./myclient/myclient_launcher.star")

def _launcher_for(lean_type):
    if lean_type == constants.LEAN_TYPE.ethlambda:
        return ethlambda_launcher
    elif lean_type == constants.LEAN_TYPE.ream:
        return ream_launcher
    elif lean_type == constants.LEAN_TYPE.zeam:
        return zeam_launcher
    elif lean_type == constants.LEAN_TYPE.myclient:
        return myclient_launcher
    fail(...)
```

---

## Touch point 4 — README + `network_params.yaml` example

Add a line to the `lean_participants:` example in `network_params.yaml`:

```yaml
lean_participants:
  - lean_type: myclient
    count: 1
    validator_count: 1
```

---

## Touch point 5 — Docs

Add your client to the list at the top of [`lean-consensus.md`](./lean-consensus.md).

---

## Required CLI flags your client must support

Your Lean client binary must accept at least the following flags (or
equivalents you can pass via `lean_extra_params`). Flag names vary across
clients; the names below mirror ethlambda — adapt to your client's CLI by
adjusting the per-client launcher.

| Concept                    | Where it comes from                                       |
|----------------------------|-----------------------------------------------------------|
| `--node-id <name>`         | Identifies the node in logs and validator-config lookups |
| `--node-key <path>`        | 32-byte hex libp2p secret (`<node_name>.key`)             |
| `--genesis <path>`         | Path to `config.yaml`                                     |
| `--validators <path>`      | Path to `annotated_validators.yaml`                       |
| `--bootnodes <path>`       | Path to `nodes.yaml`                                      |
| `--validator-config <path>`| Path to `validator-config.yaml` (per-node settings)       |
| `--hash-sig-keys-dir <dir>`| XMSS key directory                                        |
| `--data-dir <dir>`         | Persistent RocksDB / LMDB                                 |
| `--gossipsub-port <n>`     | UDP QUIC port (= `LEAN_QUIC_PORT_NUM = 9000`)             |
| `--api-port <n>`           | REST API port (= `LEAN_API_PORT_NUM = 5052`)              |
| `--metrics-port <n>`       | Prometheus metrics port (= `LEAN_METRICS_PORT_NUM = 5054`) |
| `--http-address 0.0.0.0`   | Bind address for REST + metrics                           |
| `--is-aggregator`          | Enable aggregator mode (required for finality)            |

### Required HTTP endpoints

| Path                           | Purpose                                                |
|--------------------------------|--------------------------------------------------------|
| `GET  /lean/v0/health`         | Liveness check (return 200 when healthy)               |
| `GET  /metrics` (metrics port) | Prometheus exposition (`lean_*` metric names)          |

The full Lean REST API is documented at
[ReamLabs/leanSpecs](https://github.com/ReamLabs/leanSpecs); only health
+ metrics are required for the package itself, but other endpoints
(checkpoint sync, fork choice, finalized state) are needed for richer
auxiliary services (dora, checkpointz analogues, etc.) when they appear.

---

## Required on-disk file format

Your client must read the files listed in
[`lean-consensus.md#files-mounted-into-every-lean-client`](./lean-consensus.md#files-mounted-into-every-lean-client).
Specifically:

- **`config.yaml`** with GENESIS_TIME (int), ATTESTATION_COMMITTEE_COUNT,
  ACTIVE_EPOCH, VALIDATOR_COUNT, and a GENESIS_VALIDATORS list of
  `{attestation_pubkey, proposal_pubkey}` dual-key entries (hex strings
  without `0x` prefix).
- **`annotated_validators.yaml`** mapping `<node_name>: [{index,
  pubkey_hex, privkey_file}, ...]` with privkey_file names containing
  `_attester_` or `_proposer_` to route to attestation vs proposal slots.
- **`nodes.yaml`** = list of ENRs (base64) as a YAML sequence of strings.
- **`validator-config.yaml`** matching the lean-quickstart schema (used
  by some clients for per-node ENR/metrics-port lookups).
- **`hash-sig-keys/validator_N_{attester,proposer}_key_sk.ssz`** as SSZ
  XMSS private keys.

This is the same on-disk shape produced by `lean-quickstart`'s
`generate-genesis.sh`, so a client that runs under lean-quickstart will
run under this package without code changes.

---

## Local test

```bash
# In ethereum-package root:
kurtosis run --enclave lean-test . --args-file - <<'YAML'
participants:
  - el_type: geth
    cl_type: lighthouse
    count: 1
    validator_count: 0
lean_participants:
  - lean_type: myclient
    count: 1
    is_aggregator: true
YAML

# Inspect the running service
kurtosis service shell lean-test lean-myclient_0
# Inside the container:
curl http://localhost:5052/lean/v0/health
curl http://localhost:5054/metrics | head
```

---

## Checklist

```
[ ] 1. Add LEAN_TYPE entry + DEFAULT_LEAN_IMAGES entry
[ ] 2. Create src/lean/<client>/<client>_launcher.star with initialize + start
[ ] 3. Wire dispatch in src/lean/lean_launcher.star (_launcher_for)
[ ] 4. Add an example line to network_params.yaml under lean_participants:
[ ] 5. Add the client to the supported list at the top of docs/lean-consensus.md
```
