"""
gean launcher.

Translates the Lean pipeline's per-node record into gean's CLI surface
from `client-cmds/gean-cmd.sh` in blockblaz/lean-quickstart:

    gean \
      --custom-network-config-dir <dir> \
      --gossipsub-port <quic> \
      --node-id <name> --node-key <key> \
      --http-address 0.0.0.0 --api-port <api> \
      --metrics-port <m>
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/usr/local/bin/gean"
GENESIS_MOUNT = constants.LEAN_GENESIS_MOUNTPOINT_ON_CLIENTS
HASH_SIG_MOUNT = GENESIS_MOUNT + "/hash-sig-keys"
DATA_DIR = "/data"
NODE_KEY_MOUNT = constants.LEAN_NODE_KEY_MOUNTPOINT_ON_CLIENTS

GENESIS_TEXT_FILES = [
    "config.yaml",
    "annotated_validators.yaml",
    "nodes.yaml",
    "validator-config.yaml",
    "validators.yaml",
]


def initialize(plan, node, p2p_keys_artifact, hash_sig_artifact):
    cfg_kwargs = lean_shared.common_cfg_kwargs(node)
    cfg_kwargs.update(
        {
            "image": node["image"],
            "entrypoint": ["/bin/sh", "-c"],
            "cmd": lean_shared.lean_tail_logs_cmd(node["service_name"])[2:],
            "files": {
                NODE_KEY_MOUNT: p2p_keys_artifact,
                HASH_SIG_MOUNT: hash_sig_artifact,
            },
        }
    )
    return plan.add_service(node["service_name"], ServiceConfig(**cfg_kwargs))


def start(plan, node, service, genesis_artifact, hash_sig_artifact):
    service_name = service.name
    log_file = lean_shared.lean_log_file_path(service_name)

    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "mkdir -p {0}".format(GENESIS_MOUNT)],
        ),
        description="Preparing genesis mount on {0}".format(service_name),
    )
    for filename in GENESIS_TEXT_FILES:
        read = plan.run_sh(
            run="cat /src/{0}".format(filename),
            files={"/src": genesis_artifact},
            description="Reading {0} for {1}".format(filename, service_name),
        )
        plan.exec(
            service_name=service_name,
            recipe=ExecRecipe(
                command=[
                    "/bin/sh",
                    "-c",
                    "cat > {0}/{1} <<'GEAN_EOF'\n{2}\nGEAN_EOF".format(
                        GENESIS_MOUNT,
                        filename,
                        read.output,
                    ),
                ],
            ),
            description="Staging {0} into {1}".format(filename, service_name),
        )

    # gean's contract: --custom-network-config-dir points at a dir, and
    # --node-key is resolved relative to it as `<node-id>.key`. Stage the
    # P2P key into the genesis dir so the conventional layout works.
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=[
                "/bin/sh",
                "-c",
                "cp {0}/{1}.key {2}/{1}.key".format(
                    NODE_KEY_MOUNT,
                    node["node_name"],
                    GENESIS_MOUNT,
                ),
            ],
        ),
        description="Staging node key into {0}".format(service_name),
    )

    cmd_parts = [
        ENTRYPOINT,
        "--custom-network-config-dir",
        GENESIS_MOUNT,
        "--gossipsub-port",
        str(constants.LEAN_QUIC_PORT_NUM),
        "--node-id",
        node["node_name"],
        "--node-key",
        "{0}/{1}.key".format(GENESIS_MOUNT, node["node_name"]),
        "--http-address",
        "0.0.0.0",
        "--api-port",
        str(constants.LEAN_API_PORT_NUM),
        "--metrics-port",
        str(constants.LEAN_METRICS_PORT_NUM),
    ]
    if node["is_aggregator"]:
        cmd_parts.append("--is-aggregator")
    for extra in node["extra_params"]:
        cmd_parts.append(extra)

    nohup_cmd = "setsid -f sh -c \"exec {0}\" < /dev/null >> {1} 2>&1".format(
        " ".join(cmd_parts),
        log_file,
    )
    plan.exec(
        service_name=service_name,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", nohup_cmd],
        ),
        description="Starting gean binary on {0}".format(service_name),
    )

    api_url = "http://{0}:{1}".format(service.ip_address, constants.LEAN_API_PORT_NUM)
    metrics_url = "http://{0}:{1}/metrics".format(
        service.ip_address, constants.LEAN_METRICS_PORT_NUM
    )

    return lean_context.new_lean_context(
        client_name=constants.LEAN_TYPE.gean,
        service_name=service_name,
        ip_address=service.ip_address,
        quic_port=constants.LEAN_QUIC_PORT_NUM,
        api_port=constants.LEAN_API_PORT_NUM,
        metrics_port=constants.LEAN_METRICS_PORT_NUM,
        api_url=api_url,
        metrics_url=metrics_url,
        metrics_info={
            "name": service_name,
            "url": metrics_url,
            "path": "/metrics",
            "config": node["prometheus_config"],
        },
    )
