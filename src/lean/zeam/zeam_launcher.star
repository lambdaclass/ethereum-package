"""
zeam launcher.

Translates the Lean pipeline's per-node record into zeam's CLI surface from
`client-cmds/zeam-cmd.sh` in blockblaz/lean-quickstart:

    zeam node \
      --custom-genesis <genesis-dir> \
      --validator-config <validator-config.yaml | genesis_bootnode> \
      --data-dir <dir> \
      --node-id <name> --node-key <key> \
      --metrics-enable --api-port <api> --metrics-port <m>

zeam supports the "genesis_bootnode" sentinel for participants that should
derive their validator config from GENESIS_VALIDATORS rather than reading
the per-node `validator-config.yaml`. We pass the full path here because
that's the safer default; users wanting the sentinel can set
`lean_extra_params: ["--validator-config", "genesis_bootnode"]`.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/app/zig-out/bin/zeam"
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
        "node",
        "--custom-genesis",
        GENESIS_MOUNT,
        "--validator-config",
        "{0}/validator-config.yaml".format(GENESIS_MOUNT),
        "--data-dir",
        DATA_DIR,
        "--node-id",
        node["node_name"],
        "--node-key",
        "{0}/{1}.key".format(NODE_KEY_MOUNT, node["node_name"]),
        "--metrics-enable",
        "--api-port",
        str(constants.LEAN_API_PORT_NUM),
        "--metrics-port",
        str(constants.LEAN_METRICS_PORT_NUM),
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")
    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    log_file = lean_shared.lean_log_file_path(service_name)
    full_cmd = " ".join(cmd_parts)

    new_cfg = ServiceConfig(
        image=node["image"],
        entrypoint=["/bin/sh", "-c"],
        cmd=["{0} 2>&1 | tee -a {1}".format(full_cmd, log_file)],
        ports=lean_shared.lean_port_specs(),
        files={
            NODE_KEY_MOUNT: node["_p2p_keys_artifact"],
            GENESIS_MOUNT: genesis_artifact,
        },
        env_vars=node["extra_env_vars"],
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
        client_name=constants.LEAN_TYPE.zeam,
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
