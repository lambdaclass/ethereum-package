"""
Lean Ethereum participant launcher.

Orchestrates the entire Lean pipeline:

  1. Generate per-node libp2p P2P keys (so we can render ENRs deterministically).
  2. Initialise placeholder Kurtosis services so we get assigned IPs.
  3. Run the Lean genesis pipeline (eth-beacon-genesis leanchain + hash-sig-cli)
     against the live IPs.
  4. Mount the genesis bundle into each placeholder and start the real client
     binary via `plan.exec`.

Invoked from main.star with a list of Lean records derived from
`participants:` entries whose `cl_type` is in constants.LEAN_CL_TYPES.
Each record carries the paired `el_context` (None when `el_type: none`)
so the launcher can wire Engine API for clients that implement it (today
just ethlambda — lambdaclass/ethlambda#367).
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
qlean_launcher = import_module("./qlean/qlean_launcher.star")
lantern_launcher = import_module("./lantern/lantern_launcher.star")
grandine_launcher = import_module("./grandine/grandine_launcher.star")
lighthouse_launcher = import_module("./lighthouse/lighthouse_launcher.star")
gean_launcher = import_module("./gean/gean_launcher.star")
metrics_launcher = import_module("./metrics/metrics_launcher.star")


def _launcher_for(lean_type):
    if lean_type == constants.LEAN_TYPE.ethlambda:
        return ethlambda_launcher
    elif lean_type == constants.LEAN_TYPE.ream:
        return ream_launcher
    elif lean_type == constants.LEAN_TYPE.zeam:
        return zeam_launcher
    elif lean_type == constants.LEAN_TYPE.qlean:
        return qlean_launcher
    elif lean_type == constants.LEAN_TYPE.lantern:
        return lantern_launcher
    elif lean_type == constants.LEAN_TYPE.grandine:
        return grandine_launcher
    elif lean_type == constants.LEAN_TYPE.lighthouse:
        return lighthouse_launcher
    elif lean_type == constants.LEAN_TYPE.gean:
        return gean_launcher
    fail(
        "Unsupported lean_type '{0}'. Supported: {1}. See ".format(
            lean_type,
            ", ".join(
                [
                    constants.LEAN_TYPE.ethlambda,
                    constants.LEAN_TYPE.ream,
                    constants.LEAN_TYPE.zeam,
                    constants.LEAN_TYPE.qlean,
                    constants.LEAN_TYPE.lantern,
                    constants.LEAN_TYPE.grandine,
                    constants.LEAN_TYPE.lighthouse,
                    constants.LEAN_TYPE.gean,
                ]
            ),
        )
        + "docs/lean-adding-a-new-client.md to add a new client."
    )


def launch(plan, lean_participants, lean_network_params, jwt_file=None):
    """Top-level entrypoint for the Lean pipeline.

    Returns the list of `lean_context` structs (one per running node),
    suitable for handing to Prometheus / Grafana / dora.

    `jwt_file` is the JWT artifact shared with paired ELs. It's only
    consulted for nodes that carry an `_el_context` (synthesized by
    main.star from `participants:` entries with a Lean cl_type).
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
            # `node_name` follows lean-quickstart's `<client>_<index>`
            # convention (passed as --node-id and used in validator-config.yaml).
            # Kurtosis service names, however, must match RFC 1035 — lowercase
            # letters/digits/hyphens only — so we translate any underscore in
            # the lean_type (e.g. `lean_grandine`) to a hyphen for the
            # Kurtosis-facing service name.
            node_name = "{0}_{1}".format(lean_type, idx)
            service_name = "lean-{0}-{1}".format(
                lean_type.replace("_", "-"), idx
            )
            expanded.append(
                {
                    "node_name": node_name,
                    "service_name": service_name,
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
                    # Optional Engine API pairing — populated by main.star
                    # when the participant has a non-`none` el_type.
                    # None for participants with `el_type: none` (Lean-only).
                    "_el_context": participant.get("_el_context"),
                }
            )

    node_names = [n["node_name"] for n in expanded]
    keys_artifact = p2p_keys.generate_node_keys(plan, node_names)

    # Compute the total validator count up front so we can generate the
    # hash-sig keys before any service is added. Hash-sig keys don't depend
    # on the node IP, so we can mount them directly at initialize() time
    # and avoid having to re-mount any artifact later (Kurtosis rejects
    # two add_service calls with the same name).
    total_validators = 0
    for node in expanded:
        total_validators += node["validator_count"]
    hash_sig_artifact = lean_genesis.generate_hash_sig_keys(
        plan,
        lean_network_params,
        total_validators,
    )

    # Stash both artifacts on each node record so per-client launchers
    # have access during initialize().
    for node in expanded:
        node["_p2p_keys_artifact"] = keys_artifact
        node["_hash_sig_artifact"] = hash_sig_artifact

    # Phase 1: initialise placeholder services so Kurtosis assigns IPs.
    services = []
    for node in expanded:
        launcher = _launcher_for(node["lean_type"])
        service = launcher.initialize(
            plan,
            node,
            keys_artifact,
            hash_sig_artifact,
        )
        services.append((node, service))

    # Phase 2: render the validator-config.yaml and run the genesis tool now
    # that every service has an IP. Note that we do NOT pass per-node
    # privkey values from Starlark — `plan.run_sh(...).output` is a runtime
    # future, so individual keys can't be looked up here. The genesis
    # pipeline reads `<node>.key` directly from the keys artifact inside
    # its own shell.
    services_meta = []
    for node, service in services:
        services_meta.append(
            {
                "name": node["node_name"],
                "ip_address": service.ip_address,
                "quic_port": constants.LEAN_QUIC_PORT_NUM,
                "metrics_port": constants.LEAN_METRICS_PORT_NUM,
                "api_port": constants.LEAN_API_PORT_NUM,
                "validator_count": node["validator_count"],
                "is_aggregator": node["is_aggregator"],
            }
        )

    genesis = lean_genesis.generate(
        plan,
        services_meta,
        lean_network_params,
        keys_artifact,
        hash_sig_artifact,
    )

    # Phase 2.5: for nodes with a paired EL, query the EL's genesis
    # block hash. ethlambda's `--execution-genesis-block-hash` flag seeds
    # `state.latest_execution_payload_header.block_hash` so the very first
    # `engine_forkchoiceUpdatedV3` carries a head the EL recognizes —
    # without it the EL replies SYNCING forever. The hash is the same for
    # every node sharing the same EL chain, but we still query per-EL
    # because each Lean node points at a different EL service.
    for node in expanded:
        el_context = node["_el_context"]
        if el_context == None:
            node["_el_genesis_block_hash"] = None
            continue
        # `eth_getBlockByNumber 0x0` returns the genesis header; `.hash`
        # is the 0x-prefixed 32-byte hash ethlambda expects. We strip
        # quotes/newlines for clean substitution into the CLI flag.
        rpc_url = "http://{0}:{1}".format(
            el_context.ip_addr, el_context.rpc_port_num
        )
        query = plan.run_sh(
            run='set -eu; out=$(curl -sf -X POST -H "Content-Type: application/json" '
            + '--data \'{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}\' '
            + '{0}); echo "$out" | sed -E \'s/.*"hash":"(0x[0-9a-fA-F]+)".*/\\1/\''.format(
                rpc_url
            ),
            description="Querying EL genesis block hash for {0}".format(
                node["node_name"]
            ),
            wait="5m",
        )
        node["_el_genesis_block_hash"] = query.output

    # Phase 3: hand off to each per-client launcher to mount the genesis bundle
    # and start the real binary. ethlambda accepts optional EL params; the
    # other Lean launchers ignore them.
    contexts = []
    for node, service in services:
        launcher = _launcher_for(node["lean_type"])
        if (
            node["lean_type"] == constants.LEAN_TYPE.ethlambda
            and node["_el_context"] != None
        ):
            ctx = launcher.start(
                plan,
                node,
                service,
                genesis.genesis_artifact,
                genesis.hash_sig_artifact,
                el_context=node["_el_context"],
                jwt_file=jwt_file,
                el_genesis_block_hash=node["_el_genesis_block_hash"],
            )
        else:
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

    # Phase 4: launch Prometheus + Grafana scraping every Lean node's
    # /metrics endpoint. Enabled by default; set
    # lean_network_params.metrics_enabled: false to skip.
    if lean_network_params.get("metrics_enabled", True):
        metrics_launcher.launch(plan, contexts)

    return contexts
