# Lean Ethereum consensus support

> Status: experimental. Initial integration adds the Lean Ethereum
> consensus stack as a parallel pipeline alongside the existing EL/CL
> network. Only `ethlambda` is fully wired today; `ream` and `zeam`
> have stub launchers covered by the same contract.

The Lean Ethereum protocol — sometimes called "Beam Chain" — is a redesign of
Ethereum's consensus layer built around **post-quantum (XMSS / hash-sig)
validator signatures**. Today's Lean clients run client-only devnets while
the spec stabilises: no Engine API integration yet, no JWT, just consensus
nodes peering over QUIC + libp2p gossipsub. Engine API support is on the
roadmap, after which the same Lean clients are designed to pair with EL
clients in the regular EL+CL devnet shape — which is exactly the motivation
for landing them in this package alongside the existing EL pipeline. The
Lean protocol specification lives at
[ReamLabs/leanSpecs](https://github.com/ReamLabs/leanSpecs) and is
co-developed by the teams behind
[ream](https://github.com/ReamLabs/ream) (Rust),
[zeam](https://github.com/blockblaz/zeam) (Zig),
[qlean](https://github.com/qdrvm/qlean-mini) (C++),
[lantern](https://github.com/Pier-Two/lantern) (C),
[grandine](https://github.com/grandinetech/lean/tree/main/lean_client) (Rust),
a [lighthouse](https://github.com/hopinheimer/lighthouse) fork (Rust), and
[ethlambda](https://github.com/lambdaclass/ethlambda) (Rust).

This document describes how `ethereum-package` runs Lean networks. To add a
new Lean client, see
[`lean-adding-a-new-client.md`](./lean-adding-a-new-client.md).

---

## Why a parallel pipeline?

Lean consensus today differs from the EL/CL pipeline along several axes that
shaped the original `participant_network` design:

| Concern                | EL/CL                          | Lean (today)                  |
|------------------------|--------------------------------|-------------------------------|
| Genesis tool           | `ethereum-genesis-generator`   | `eth-beacon-genesis leanchain` |
| Validator signatures   | BLS                            | XMSS (hash-sig)               |
| Validator key keystore | EIP-2335 JSON                  | SSZ `validator_N_*_key_*.ssz` |
| EL pairing             | 1 EL + 1 CL (+ optional VC)    | Client-only (no EL yet)       |
| Engine API + JWT       | Required                       | Not implemented yet           |
| RPC ports              | Engine RPC + JWT + REST + WS   | REST + Prometheus             |
| P2P transport          | TCP + UDP discovery + libp2p   | QUIC-only (libp2p)            |
| Block production       | EL builds payload, CL attests  | Single-stack: 4 s slots       |

Trying to express Lean clients as `participants[].cl_type` with `el_type: none`
would force `if is_lean(): ... else:` branches throughout the EL/CL pipeline,
the validator-keystore generator, the genesis generator, the MEV-boost flow,
the snooper, etc. A parallel pipeline keeps those code paths untouched and
isolates Lean-specific concerns under `src/lean/` and
`src/prelaunch_data_generator/lean_genesis/`.

Once Lean clients ship Engine API support, the design intent is for the
two pipelines to compose: a Lean participant declares its EL counterpart
the same way today's CL clients do, JWT is shared, and the existing
EL-side plumbing (image discovery, MEV-boost, snooper, dora) keeps
working. Until then, the realistic devnet shape is Lean-only.

The package still composes the two: Prometheus/Grafana discover Lean nodes
through their service labels and metrics ports, and additional services that
don't depend on EL state (e.g. dora's beacon explorer) can be pointed at Lean
nodes by URL.

---

## Quick start

Today's Lean clients run client-only (no Engine API yet), so the realistic
devnet shape is Lean-only — the args file contains `lean_participants:` and
`participants: []` to skip the Eth1 EL/CL flow:

```yaml
participants: []

lean_participants:
  - lean_type: ethlambda
    count: 4
    validator_count: 1
    is_aggregator: true
```

Then run:

```bash
kurtosis run --enclave lean-test github.com/ethpandaops/ethereum-package --args-file your-args.yaml
```

The Lean pipeline produces 4 services named `lean-ethlambda_0` …
`lean-ethlambda_3`, each exposing:

| Port  | Purpose                                          |
|-------|--------------------------------------------------|
| 9000  | libp2p QUIC (UDP) — block + attestation gossip   |
| 5052  | REST API (`GET /lean/v0/health`, fork choice, …) |
| 5054  | Prometheus metrics (`/metrics`)                  |

### Mixed mode (Lean + EL/CL)

You can also run Lean alongside the existing Eth1 EL/CL network in the same
enclave. Both pipelines run independently — there is no cross-talk between
them. Add `participants:` entries as you normally would and keep
`lean_participants:` populated. This is useful for side-by-side benchmarking
and observability dashboards that scrape both.

---

## Pipeline architecture

The Lean launcher (`src/lean/lean_launcher.star`) runs in three phases.
Phases 1 and 3 are per-node; phase 2 is global.

```
                                     ┌──────────────────────────────────┐
                  Phase 1            │ openssl: generate <node>.key x N │
                                     └──────────────────────────────────┘
                                                       │
                                                       ▼
            ┌────────────────────────────────────────────────────────────┐
            │ For each Lean participant entry:                           │
            │   plan.add_service(name=lean-<type>_<idx>, cmd="tail -f")  │
            │   Kurtosis assigns an IP to each service.                  │
            └────────────────────────────────────────────────────────────┘
                                                       │
                  Phase 2                              ▼
            ┌────────────────────────────────────────────────────────────┐
            │ hash-sig-cli: generate XMSS attester+proposer keys (SSZ)   │
            │ render validator-config.yaml from live IPs + ports         │
            │ render initial config.yaml (GENESIS_TIME etc.)             │
            │ eth-beacon-genesis leanchain: write nodes.yaml,            │
            │   validators.yaml, genesis.{ssz,json}, update config.yaml  │
            │ post-process: inject GENESIS_VALIDATORS into config.yaml,  │
            │   render annotated_validators.yaml from manifest           │
            └────────────────────────────────────────────────────────────┘
                                                       │
                  Phase 3                              ▼
            ┌────────────────────────────────────────────────────────────┐
            │ For each placeholder service:                              │
            │   plan.add_service(name=<same>, force_update=True,         │
            │     mounts={genesis_artifact, hash_sig_artifact, keys},    │
            │     cmd=<real client binary + flags>)                      │
            │   Kurtosis preserves the IP (same name + ports).           │
            └────────────────────────────────────────────────────────────┘
```

Why three phases? Because the genesis tool needs every node's IP and port to
render `nodes.yaml` (the bootnode list), but Kurtosis only assigns IPs after
`add_service`. Pre-allocating placeholder services then re-issuing them with
`force_update=True` keeps the IP stable while letting us mount the
just-generated genesis bundle.

---

## Files mounted into every Lean client

All Lean clients receive the same on-disk layout. This matches the layout
produced by `lean-quickstart`'s `generate-genesis.sh` so a Lean client that
runs under `lean-quickstart` runs under this package without code changes.

| Path                                                  | Source                       | Contents                                                        |
|-------------------------------------------------------|------------------------------|-----------------------------------------------------------------|
| `/network-configs/config.yaml`                        | Lean genesis post-process    | GENESIS_TIME, ATTESTATION_COMMITTEE_COUNT, ACTIVE_EPOCH, VALIDATOR_COUNT, GENESIS_VALIDATORS (per-validator attestation/proposal pubkeys) |
| `/network-configs/validators.yaml`                    | PK's eth-beacon-genesis      | `node_name -> [validator_index]` round-robin assignments        |
| `/network-configs/annotated_validators.yaml`          | Lean genesis post-process    | `node_name -> [{index, pubkey_hex, privkey_file}]`              |
| `/network-configs/nodes.yaml`                         | PK's eth-beacon-genesis      | ENR list for all Lean nodes (bootnodes)                         |
| `/network-configs/validator-config.yaml`              | Lean launcher (rendered)     | Per-node config (name, privkey, IP, ports, count, isAggregator) |
| `/network-configs/genesis.ssz`                        | PK's eth-beacon-genesis      | SSZ genesis state                                               |
| `/network-configs/genesis.json`                       | PK's eth-beacon-genesis      | JSON genesis state                                              |
| `/network-configs/<node_name>.key`                    | openssl prelaunch step       | 32-byte hex libp2p secret for this node                         |
| `/network-configs/hash-sig-keys/validator_N_attester_key_{sk,pk}.ssz` | hash-sig-cli  | XMSS attester keypair per validator                             |
| `/network-configs/hash-sig-keys/validator_N_proposer_key_{sk,pk}.ssz` | hash-sig-cli  | XMSS proposer keypair per validator                             |
| `/network-configs/hash-sig-keys/validator-keys-manifest.yaml`        | hash-sig-cli  | Dual-key manifest mapping validator index to attester/proposer pubkey hex |
| `/node-keys/<node_name>.key`                          | openssl prelaunch step       | Same as above; kept at a separate mount for clients that expect this layout |

> Clients SHOULD derive their genesis state from `config.yaml` directly
> (using GENESIS_VALIDATORS pubkeys and GENESIS_TIME). The `genesis.json` /
> `genesis.ssz` files are provided for compatibility but their format may
> drift across leanSpec revisions.

---

## Port contract

| Port  | Protocol | Purpose                       |
|-------|----------|-------------------------------|
| 9000  | UDP      | libp2p QUIC (block + attestation gossipsub) |
| 5052  | TCP HTTP | REST API (must implement `GET /lean/v0/health`) |
| 5054  | TCP HTTP | Prometheus metrics (`/metrics`) |

These match the defaults used by every Lean client in `lean-quickstart` so
operator-facing dashboards and probes work across deployments.

---

## Components added

| Path                                                            | Purpose                                                                  |
|-----------------------------------------------------------------|--------------------------------------------------------------------------|
| `src/package_io/constants.star`                                 | `LEAN_TYPE` enum, default port nums, mountpoints, genesis-tool images.   |
| `src/package_io/input_parser.star`                              | `lean_participants` / `lean_network_params` parsing + defaults.          |
| `src/prelaunch_data_generator/lean_genesis/p2p_keys_generator.star` | Generates one 32-byte hex libp2p secret per node (openssl).          |
| `src/prelaunch_data_generator/lean_genesis/lean_genesis_generator.star` | Full Lean genesis pipeline (hash-sig + leanchain + post-process). |
| `src/lean/lean_launcher.star`                                   | Dispatches per-client launchers, runs the three-phase lifecycle.         |
| `src/lean/lean_context.star`                                    | Per-node context struct returned to `main.star`.                         |
| `src/lean/lean_shared.star`                                     | Common port specs, mountpoint helpers, log file conventions.             |
| `src/lean/ethlambda/ethlambda_launcher.star`                    | First fully-wired client.                                                |
| `src/lean/ream/ream_launcher.star`                              | Stub mirroring `client-cmds/ream-cmd.sh`.                                |
| `src/lean/zeam/zeam_launcher.star`                              | Stub mirroring `client-cmds/zeam-cmd.sh`.                                |
| `main.star`                                                     | Single call site for `lean_launcher.launch(...)`.                        |
| `network_params.yaml`                                           | Documented `lean_participants:` example + default `lean_network_params`. |

---

## Limitations & follow-ups

1. **Lean nodes are not yet scraped by Prometheus.** The `metrics_info`
   struct is populated on every `lean_context`, but the prometheus
   launcher isn't yet wired to discover Lean nodes. Operators scraping
   Lean nodes today should hit them by service name directly.
2. **`hash-sig-cli` image is pinned to `:latest`.** Pinning to a SHA is
   left to a follow-up; override via
   `lean_network_params.hash_sig_cli_image`.
3. **No Lean-specific dashboards.** Existing Grafana dashboards assume the
   Ethereum CL schema. Lean dashboards (`lean_head_slot`,
   `lean_state_transition_time_seconds`, etc.) need a separate dashboard
   pack.
4. **No checkpoint sync.** Per-participant `checkpoint_sync_url` parsing
   is not yet wired through to the per-client launchers.
5. **Mixed-mode auxiliary services.** When Lean is run alongside EL/CL,
   the existing Eth1 auxiliary services (tx-fuzz, dora, etc.) only see
   the EL/CL participants. Wiring them to also point at Lean nodes is a
   follow-up.
