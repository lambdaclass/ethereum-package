"""
Lean Ethereum participant launcher.

Orchestrates the entire Lean pipeline:

  1. Generate per-node libp2p P2P keys (so we can render ENRs deterministically).
  2. Initialise placeholder Kurtosis services so we get assigned IPs.
  3. Run the Lean genesis pipeline (eth-beacon-genesis leanchain + hash-sig-cli)
     against the live IPs.
  4. Mount the genesis bundle into each placeholder and start the real client
     binary via `plan.exec`.

This is intentionally independent of the EL/CL `participant_network` pipeline:
Lean consensus has no Engine API, no JWT, no EL pairing. Operators opt in by
populating `lean_participants:` in their args; the existing EL/CL flow runs
unchanged either way.
"""

constants = import_module("../package_io/constants.star")
lean_shared = import_module("./lean_shared.star")
lean_genesis = import_module(
    "../prelaunch_data_generator/lean_genesis/lean_genesis_generator.star"
)
p2p_keys = import_module(
    "../prelaunch_data_generator/lean_genesis/p2p_keys_generator.star"
)

ethlambda_launcher = import_module("./ethlambda/ethlambda_launcher.star")
ream_launcher = import_module("./ream/ream_launcher.star")
zeam_launcher = import_module("./zeam/zeam_launcher.star")


def _launcher_for(lean_type):
    if lean_type == constants.LEAN_TYPE.ethlambda:
        return ethlambda_launcher
    elif lean_type == constants.LEAN_TYPE.ream:
        return ream_launcher
    elif lean_type == constants.LEAN_TYPE.zeam:
        return zeam_launcher
    fail(
        "Unsupported lean_type '{0}'. Supported: {1}. See ".format(
            lean_type,
            ", ".join(
                [
                    constants.LEAN_TYPE.ethlambda,
                    constants.LEAN_TYPE.ream,
                    constants.LEAN_TYPE.zeam,
                ]
            ),
        )
        + "docs/lean-adding-a-new-client.md to add a new client."
    )


def launch(plan, lean_participants, lean_network_params):
    """Top-level entrypoint for the Lean pipeline.

    Returns the list of `lean_context` structs (one per running node),
    suitable for handing to Prometheus / Grafana / dora.
    """
    if not lean_participants:
        return []

    # Expand per-participant `count` to a flat list of (type, image, ...) records.
    # Naming follows lean-quickstart's `<client>_<index>` convention so a
    # Lean client's existing log parsers and dashboards work unchanged.
    expanded = []
    type_counters = {}
    for participant in lean_participants:
        lean_type = participant["lean_type"]
        for _ in range(participant["count"]):
            idx = type_counters.get(lean_type, 0)
            type_counters[lean_type] = idx + 1
            node_name = "{0}_{1}".format(lean_type, idx)
            expanded.append(
                {
                    "node_name": node_name,
                    "service_name": "lean-{0}".format(node_name),
                    "lean_type": lean_type,
                    "image": participant["lean_image"],
                    "validator_count": participant.get(
                        "validator_count",
                        lean_network_params["num_validator_keys_per_node"],
                    ),
                    "is_aggregator": participant.get("is_aggregator", False),
                    "extra_params": participant.get("lean_extra_params", []),
                    "extra_env_vars": participant.get("lean_extra_env_vars", {}),
                    "extra_labels": participant.get("lean_extra_labels", {}),
                    "log_level": participant.get("lean_log_level", ""),
                    "min_cpu": participant.get("lean_min_cpu", 0),
                    "max_cpu": participant.get("lean_max_cpu", 0),
                    "min_mem": participant.get("lean_min_mem", 0),
                    "max_mem": participant.get("lean_max_mem", 0),
                    "node_selectors": participant.get("node_selectors", {}),
                    "tolerations": participant.get("tolerations", []),
                    "prometheus_config": participant.get(
                        "prometheus_config",
                        {
                            "scrape_interval": "15s",
                            "labels": {},
                        },
                    ),
                }
            )

    node_names = [n["node_name"] for n in expanded]
    keys_result = p2p_keys.generate_node_keys(plan, node_names)

    # Stash the P2P keys artifact on each node record so per-client launchers
    # can re-mount it during the `start()` phase (where we re-issue the
    # add_service with the full mounts).
    for node in expanded:
        node["_p2p_keys_artifact"] = keys_result.artifact_name

    # Phase 1: initialise placeholder services so Kurtosis assigns IPs.
    services = []
    for node in expanded:
        launcher = _launcher_for(node["lean_type"])
        service = launcher.initialize(
            plan,
            node,
            keys_result.artifact_name,
        )
        services.append((node, service))

    # Phase 2: render the validator-config.yaml and run the genesis tool now
    # that every service has an IP.
    services_meta = []
    for node, service in services:
        services_meta.append(
            {
                "name": node["node_name"],
                "ip_address": service.ip_address,
                "quic_port": constants.LEAN_QUIC_PORT_NUM,
                "metrics_port": constants.LEAN_METRICS_PORT_NUM,
                "api_port": constants.LEAN_API_PORT_NUM,
                "privkey": keys_result.keys[node["node_name"]],
                "validator_count": node["validator_count"],
                "is_aggregator": node["is_aggregator"],
            }
        )

    genesis = lean_genesis.generate(
        plan,
        services_meta,
        lean_network_params,
        keys_result.artifact_name,
    )

    # Phase 3: hand off to each per-client launcher to mount the genesis bundle
    # and start the real binary.
    contexts = []
    for node, service in services:
        launcher = _launcher_for(node["lean_type"])
        ctx = launcher.start(
            plan,
            node,
            service,
            genesis.genesis_artifact,
            genesis.hash_sig_artifact,
        )
        contexts.append(ctx)

    plan.print(
        "Lean pipeline ready: {0} nodes, GENESIS_TIME={1}".format(
            len(contexts),
            genesis.genesis_time,
        )
    )
    return contexts
