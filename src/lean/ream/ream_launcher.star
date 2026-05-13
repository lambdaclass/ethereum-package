"""
ream launcher.

Mirrors the ethlambda launcher shape (placeholder service -> genesis pipeline
-> re-issue with full mounts) but translates to ream's CLI surface as
documented in `client-cmds/ream-cmd.sh` in blockblaz/lean-quickstart:

    ream --data-dir <dir> lean_node \
         --network <config.yaml> \
         --validator-registry-path <annotated_validators.yaml> \
         --bootnodes <nodes.yaml> \
         --node-id <name> --node-key <key> \
         --socket-port <quic> \
         --metrics --metrics-address 0.0.0.0 --metrics-port <m> \
         --http-address 0.0.0.0 --http-port <api>

NOTE: ream's `lean_node` subcommand doesn't (yet) consume a hash-sig-keys
directory in its public CLI - it derives its validator set from
`annotated_validators.yaml` + GENESIS_VALIDATORS in config.yaml. The genesis
artifact we mount carries both, so ream needs no extra plumbing.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/usr/local/bin/ream"
GENESIS_MOUNT = constants.LEAN_GENESIS_MOUNTPOINT_ON_CLIENTS
HASH_SIG_MOUNT = GENESIS_MOUNT + "/hash-sig-keys"
DATA_DIR = "/data"
NODE_KEY_MOUNT = constants.LEAN_NODE_KEY_MOUNTPOINT_ON_CLIENTS


def initialize(plan, node, p2p_keys_artifact):
    cfg = ServiceConfig(
        image=node["image"],
        entrypoint=["/bin/sh", "-c"],
        cmd=lean_shared.lean_tail_logs_cmd(node["service_name"])[2:],
        ports=lean_shared.lean_port_specs(),
        files={NODE_KEY_MOUNT: p2p_keys_artifact},
        env_vars=node["extra_env_vars"],
        labels=node["extra_labels"],
        min_cpu=node["min_cpu"],
        max_cpu=node["max_cpu"],
        min_memory=node["min_mem"],
        max_memory=node["max_mem"],
        node_selectors=node["node_selectors"],
        tolerations=node["tolerations"],
    )
    return plan.add_service(node["service_name"], cfg)


def start(plan, node, service, genesis_artifact, hash_sig_artifact):
    service_name = service.name

    cmd_parts = [
        ENTRYPOINT,
        "--data-dir",
        DATA_DIR,
        "lean_node",
        "--network",
        "{0}/config.yaml".format(GENESIS_MOUNT),
        "--validator-registry-path",
        "{0}/annotated_validators.yaml".format(GENESIS_MOUNT),
        "--bootnodes",
        "{0}/nodes.yaml".format(GENESIS_MOUNT),
        "--node-id",
        node["node_name"],
        "--node-key",
        "{0}/{1}.key".format(NODE_KEY_MOUNT, node["node_name"]),
        "--socket-port",
        str(constants.LEAN_QUIC_PORT_NUM),
        "--metrics",
        "--metrics-address",
        "0.0.0.0",
        "--metrics-port",
        str(constants.LEAN_METRICS_PORT_NUM),
        "--http-address",
        "0.0.0.0",
        "--http-port",
        str(constants.LEAN_API_PORT_NUM),
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")
    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    log_file = lean_shared.lean_log_file_path(service_name)
    full_cmd = " ".join(cmd_parts)

    env_vars = dict(node["extra_env_vars"])
    if node["log_level"] != "":
        env_vars["RUST_LOG"] = node["log_level"]

    new_cfg = ServiceConfig(
        image=node["image"],
        entrypoint=["/bin/sh", "-c"],
        cmd=["{0} 2>&1 | tee -a {1}".format(full_cmd, log_file)],
        ports=lean_shared.lean_port_specs(),
        files={
            NODE_KEY_MOUNT: node["_p2p_keys_artifact"],
            GENESIS_MOUNT: genesis_artifact,
        },
        env_vars=env_vars,
        labels=node["extra_labels"],
        min_cpu=node["min_cpu"],
        max_cpu=node["max_cpu"],
        min_memory=node["min_mem"],
        max_memory=node["max_mem"],
        node_selectors=node["node_selectors"],
        tolerations=node["tolerations"],
    )
    new_service = plan.add_service(
        name=service_name,
        config=new_cfg,
        force_update=True,
    )

    api_url = "http://{0}:{1}".format(
        new_service.ip_address, constants.LEAN_API_PORT_NUM
    )
    metrics_url = "http://{0}:{1}/metrics".format(
        new_service.ip_address,
        constants.LEAN_METRICS_PORT_NUM,
    )

    return lean_context.new_lean_context(
        client_name=constants.LEAN_TYPE.ream,
        service_name=new_service.name,
        ip_address=new_service.ip_address,
        quic_port=constants.LEAN_QUIC_PORT_NUM,
        api_port=constants.LEAN_API_PORT_NUM,
        metrics_port=constants.LEAN_METRICS_PORT_NUM,
        api_url=api_url,
        metrics_url=metrics_url,
        metrics_info={
            "name": new_service.name,
            "url": metrics_url,
            "path": "/metrics",
            "config": node["prometheus_config"],
        },
    )
