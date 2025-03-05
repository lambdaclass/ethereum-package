shared_utils = import_module("../../shared_utils/shared_utils.star")
input_parser = import_module("../../package_io/input_parser.star")
el_context = import_module("../../el/el_context.star")
el_admin_node_info = import_module("../../el/el_admin_node_info.star")
node_metrics = import_module("../../node_metrics_info.star")
constants = import_module("../../package_io/constants.star")
el_shared = import_module("../el_shared.star")

RPC_PORT_NUM = 8545
WS_PORT_NUM = 8546
DISCOVERY_PORT_NUM = 30303
ENGINE_RPC_PORT_NUM = 8551
METRICS_PORT_NUM = 9001

# Port IDs
RPC_PORT_ID = "rpc"
WS_PORT_ID = "ws"
TCP_DISCOVERY_PORT_ID = "tcp-discovery"
UDP_DISCOVERY_PORT_ID = "udp-discovery"
ENGINE_RPC_PORT_ID = "engine-rpc"
METRICS_PORT_ID = "metrics"

# Paths
METRICS_PATH = "/metrics"
EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER = "/data/ethrex/execution-data"

def get_used_ports(discovery_port=DISCOVERY_PORT_NUM):
    used_ports = {
        RPC_PORT_ID: shared_utils.new_port_spec(
            RPC_PORT_NUM,
            shared_utils.TCP_PROTOCOL,
            shared_utils.HTTP_APPLICATION_PROTOCOL,
        ),
        # WS_PORT_ID: shared_utils.new_port_spec(WS_PORT_NUM, shared_utils.TCP_PROTOCOL),
        # TCP_DISCOVERY_PORT_ID: shared_utils.new_port_spec(
        #     discovery_port, shared_utils.TCP_PROTOCOL
        # ),
        # UDP_DISCOVERY_PORT_ID: shared_utils.new_port_spec(
        #     discovery_port, shared_utils.UDP_PROTOCOL
        # ),
        ENGINE_RPC_PORT_ID: shared_utils.new_port_spec(
            ENGINE_RPC_PORT_NUM, shared_utils.TCP_PROTOCOL
        ),
        # METRICS_PORT_ID: shared_utils.new_port_spec(
        #     METRICS_PORT_NUM, shared_utils.TCP_PROTOCOL
        # ),
    }
    return used_ports


ENTRYPOINT_ARGS = ["sh", "-c"]

VERBOSITY_LEVELS = {
    constants.GLOBAL_LOG_LEVEL.error: "1",
    constants.GLOBAL_LOG_LEVEL.warn: "2",
    constants.GLOBAL_LOG_LEVEL.info: "3",
    constants.GLOBAL_LOG_LEVEL.debug: "4",
    constants.GLOBAL_LOG_LEVEL.trace: "5",
}


def launch(
    plan,
    launcher,
    service_name,
    participant,
    global_log_level,
    # If empty then the node will be launched as a bootnode
    existing_el_clients,
    persistent,
    tolerations,
    node_selectors,
    port_publisher,
    participant_index
):
    image = participant.el_image
    participant_log_level = participant.el_log_level
    extra_params = participant.el_extra_params
    extra_env_vars = participant.el_extra_env_vars
    extra_labels = participant.el_extra_labels
    el_volume_size = participant.el_volume_size

    log_level = input_parser.get_client_log_level_or_default(
        participant_log_level, global_log_level, VERBOSITY_LEVELS
    )

    network_name = shared_utils.get_network_name(launcher.network)
    cl_client_name = service_name.split("-")[3]

    config = get_config(
        plan,
        launcher.el_cl_genesis_data,
        launcher.jwt_file,
        launcher.network,
        image,
        service_name,
        existing_el_clients,
        cl_client_name,
        log_level,
        participant,
        extra_params,
        extra_env_vars,
        extra_labels,
        persistent,
        el_volume_size,
        tolerations,
        node_selectors,
        port_publisher,
        participant_index
    )

    service = plan.add_service(service_name, config)

    enode = el_admin_node_info.get_enode_for_node(plan, service_name, RPC_PORT_ID)

    metric_url = "{0}:{1}".format(service.ip_address, METRICS_PORT_NUM)
    metrics_info = node_metrics.new_node_metrics_info(
        service_name, METRICS_PATH, metric_url
    )

    http_url = "http://{0}:{1}".format(service.ip_address, RPC_PORT_NUM)
    ws_url = "ws://{0}:{1}".format(service.ip_address, WS_PORT_NUM)

    return el_context.new_el_context(
        client_name="ethrex",
        enode=enode,
        ip_addr=service.ip_address,
        rpc_port_num=RPC_PORT_NUM,
        ws_port_num=WS_PORT_NUM,
        engine_rpc_port_num=ENGINE_RPC_PORT_NUM,
        rpc_http_url=http_url,
        ws_url=ws_url,
        enr="", # ethrex has no enr?
        service_name=service_name,
        el_metrics_info=[metrics_info],
    )


def get_config(
    plan,
    el_cl_genesis_data,
    jwt_file,
    network,
    image,
    service_name,
    existing_el_clients,
    cl_client_name,
    verbosity_level,
    participant,
    extra_params,
    extra_env_vars,
    extra_labels,
    persistent,
    el_volume_size,
    tolerations,
    node_selectors,
    port_publisher,
    participant_index
):

    used_ports = get_used_ports()
    public_ports = used_ports

    cmd = [
        "ethrex",
        # "-{0}".format(verbosity_level),
        "--datadir=" + EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER,
        "--network={0}".format(
            network
            if network in constants.PUBLIC_NETWORKS
            else constants.GENESIS_CONFIG_MOUNT_PATH_ON_CONTAINER + "/genesis.json"
        ),
        # "--http",
        "--http.port={0}".format(RPC_PORT_NUM),
        "--http.addr=0.0.0.0",
        # "--http.corsdomain=*",
        # # WARNING: The admin info endpoint is enabled so that we can easily get ENR/enode, which means
        # #  that users should NOT store private information in these Kurtosis nodes!
        # "--http.api=admin,net,eth,web3,debug,trace",
        # "--ws",
        # "--ws.addr=0.0.0.0",
        # "--ws.port={0}".format(WS_PORT_NUM),
        # "--ws.api=net,eth",
        # "--ws.origins=*",
        # "--nat=extip:" + port_publisher.nat_exit_ip,
        "--authrpc.port={0}".format(ENGINE_RPC_PORT_NUM),
        "--authrpc.jwtsecret=" + constants.JWT_MOUNT_PATH_ON_CONTAINER,
        "--authrpc.addr=0.0.0.0",
        # "--metrics=0.0.0.0:{0}".format(METRICS_PORT_NUM),
        # "--discovery.port={0}".format(discovery_port),
    ]
    if network == constants.NETWORK_NAME.kurtosis:
        if len(existing_el_clients) > 0:
            cmd.append(
                "--bootnodes="
                + ",".join(
                    [
                        ctx.enode
                        for ctx in existing_el_clients[: constants.MAX_ENODE_ENTRIES]
                    ]
                )
            )
    elif network not in constants.PUBLIC_NETWORKS:
        cmd.append(
            "--bootnodes="
            + shared_utils.get_devnet_enodes(
                plan, el_cl_genesis_data.files_artifact_uuid
            )
        )

    if len(extra_params) > 0:
        # this is a repeated<proto type>, we convert it into Starlark
        cmd.extend([param for param in extra_params])

    cmd_str = " ".join(cmd)
    if network not in constants.PUBLIC_NETWORKS:
        # subcommand_strs = [
        #     init_datadir_cmd_str,
        #     cmd_str,
        # ]
        subcommand_strs = [cmd_str]
    else:
        subcommand_strs = [cmd_str]

    command_str = " && ".join(subcommand_strs)

    files = {
        constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS: el_cl_genesis_data.files_artifact_uuid,
        constants.JWT_MOUNTPOINT_ON_CLIENTS: jwt_file,
    }

    # if persistent:
    #     files[EXECUTION_DATA_DIRPATH_ON_CLIENT_CONTAINER] = Directory(
    #         persistent_key="data-{0}".format(service_name),
    #         size=el_volume_size,
    #     )

    config_args = {
        "image": image,
        "ports": used_ports,
        "public_ports": public_ports,
        "cmd": [command_str],
        "files": files,
        "entrypoint": ENTRYPOINT_ARGS,
        "private_ip_address_placeholder": constants.PRIVATE_IP_ADDRESS_PLACEHOLDER,
        "env_vars": extra_env_vars,
        "labels": shared_utils.label_maker(
            constants.EL_TYPE.ethrex,
            constants.CLIENT_TYPES.el,
            image,
            cl_client_name,
            extra_labels,
        ),
        "tolerations": tolerations,
        "node_selectors": node_selectors,
    }


    if participant.el_min_cpu > 0:
        config_args["min_cpu"] = participant.el_min_cpu
    if participant.el_max_cpu > 0:
        config_args["max_cpu"] = participant.el_max_cpu
    if participant.el_min_mem > 0:
        config_args["min_memory"] = participant.el_min_mem
    if participant.el_max_mem > 0:
        config_args["max_memory"] = participant.el_max_mem

    return ServiceConfig(**config_args)


def new_ethrex_launcher(el_cl_genesis_data, jwt_file, network):
    return struct(
        el_cl_genesis_data=el_cl_genesis_data,
        jwt_file=jwt_file,
        network=network,
    )
