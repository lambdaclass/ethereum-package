"""
ethlambda launcher.

Translates the Lean pipeline's per-node record into the ethlambda CLI surface
(see lambdaclass/ethlambda's `bin/ethlambda/src/main.rs` and the matching
lean-quickstart `client-cmds/ethlambda-cmd.sh`).

Lifecycle (called by ../lean_launcher.star):
  1. `initialize()` - add a Kurtosis service holding the P2P keys + the
     pre-generated hash-sig keys (these don't depend on the node IP). The
     container runs `tail -f` on a log file so it stays alive while the
     genesis pipeline computes things downstream that DO need the IP.
  2. `start()` - after the genesis tool has produced the text artifacts
     (config.yaml, annotated_validators.yaml, nodes.yaml, validator-config.yaml),
     stage them inside the running container via `plan.exec` and launch
     the ethlambda binary as a backgrounded `nohup` process.

Why two phases rather than one `add_service` with everything mounted? Because
the genesis tool needs every node's IP to render `nodes.yaml`, and Kurtosis
only assigns IPs after `add_service`. Recreating services to swap mounts
would also reshuffle IPs and invalidate the ENRs we just embedded.
"""

constants = import_module("../../package_io/constants.star")
lean_shared = import_module("../lean_shared.star")
lean_context = import_module("../lean_context.star")

ENTRYPOINT = "/usr/local/bin/ethlambda"
GENESIS_MOUNT = constants.LEAN_GENESIS_MOUNTPOINT_ON_CLIENTS
HASH_SIG_MOUNT = GENESIS_MOUNT + "/hash-sig-keys"
DATA_DIR = "/data"
NODE_KEY_MOUNT = constants.LEAN_NODE_KEY_MOUNTPOINT_ON_CLIENTS


def initialize(plan, node, p2p_keys_artifact):
    """Phase 1: stand the placeholder service up so Kurtosis assigns an IP."""
    cfg = ServiceConfig(
        image=node["image"],
        # Override the image ENTRYPOINT so the container doesn't try to start
        # ethlambda with no flags before we've written the genesis files in.
        entrypoint=["/bin/sh", "-c"],
        cmd=lean_shared.lean_tail_logs_cmd(node["service_name"])[2:],
        ports=lean_shared.lean_port_specs(),
        files={
            NODE_KEY_MOUNT: p2p_keys_artifact,
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
    return plan.add_service(node["service_name"], cfg)


def start(plan, node, service, genesis_artifact, hash_sig_artifact):
    """Phase 3: mount genesis files and start the ethlambda binary.

    We re-issue add_service with force_update=True so we can mount the
    genesis + hash-sig artifacts (Kurtosis preserves the IP because the
    service name and port assignments are unchanged; ENR fields embedded
    in the genesis bundle therefore remain valid).
    """
    service_name = service.name

    cmd_parts = [
        ENTRYPOINT,
        "--genesis",
        "{0}/config.yaml".format(GENESIS_MOUNT),
        "--validators",
        "{0}/annotated_validators.yaml".format(GENESIS_MOUNT),
        "--bootnodes",
        "{0}/nodes.yaml".format(GENESIS_MOUNT),
        "--validator-config",
        "{0}/validator-config.yaml".format(GENESIS_MOUNT),
        "--hash-sig-keys-dir",
        HASH_SIG_MOUNT,
        "--data-dir",
        DATA_DIR,
        "--gossipsub-port",
        str(constants.LEAN_QUIC_PORT_NUM),
        "--node-id",
        node["node_name"],
        "--node-key",
        "{0}/{1}.key".format(NODE_KEY_MOUNT, node["node_name"]),
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

    log_file = lean_shared.lean_log_file_path(service_name)
    full_cmd = " ".join(cmd_parts)

    env_vars = dict(node["extra_env_vars"])
    if node["log_level"] != "":
        env_vars["RUST_LOG"] = node["log_level"]

    new_cfg = ServiceConfig(
        image=node["image"],
        entrypoint=["/bin/sh", "-c"],
        # `tee -a` keeps a log file readable by Kurtosis's `service logs`
        # while also surfacing the binary's stdout/stderr live.
        cmd=[
            "{0} 2>&1 | tee -a {1}".format(full_cmd, log_file),
        ],
        ports=lean_shared.lean_port_specs(),
        # The hash-sig keys are bundled inside the genesis artifact under
        # ./hash-sig-keys (see lean_genesis_generator._post_process); Kurtosis
        # forbids overlapping file artifact mounts so we only mount the
        # genesis bundle here and let HASH_SIG_MOUNT resolve transparently.
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
        new_service.ip_address,
        constants.LEAN_API_PORT_NUM,
    )
    metrics_url = "http://{0}:{1}/metrics".format(
        new_service.ip_address,
        constants.LEAN_METRICS_PORT_NUM,
    )

    return lean_context.new_lean_context(
        client_name=constants.LEAN_TYPE.ethlambda,
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
