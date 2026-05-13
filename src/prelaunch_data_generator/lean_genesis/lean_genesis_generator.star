"""
Lean Ethereum genesis generation.

This module orchestrates the post-quantum genesis pipeline used by every
Lean client:

  1. Generate XMSS attester+proposer keypairs via `blockblaz/hash-sig-cli`.
  2. Render `validator-config.yaml` from the live (Kurtosis-assigned) IPs and
     ports of each Lean participant.
  3. Run `ethpandaops/eth-beacon-genesis:pk910-leanchain` to derive
     `config.yaml`, `validators.yaml`, `nodes.yaml`, and `genesis.{ssz,json}`.
  4. Post-process: inject GENESIS_VALIDATORS into config.yaml and render
     `annotated_validators.yaml` (node-name -> validator-index assignments
     with attester/proposer privkey filenames).

The output is a single files artifact (`lean-genesis-data`) mounted at
`/network-configs` inside every Lean client container, plus a separate
`lean-hash-sig-keys` artifact for the XMSS secret/public keys. This matches
the `lean-quickstart` on-disk layout 1:1 so a client written for
lean-quickstart works under Kurtosis without code changes.
"""

constants = import_module("../../package_io/constants.star")

GENESIS_ARTIFACT_NAME = "lean-genesis-data"
HASH_SIG_ARTIFACT_NAME = "lean-hash-sig-keys"

GENESIS_DIR = "/genesis"
HASH_SIG_DIR = "/hash-sig-keys"


def _resolve_images(lean_network_params):
    genesis_image = lean_network_params.get("genesis_generator_image", "")
    if genesis_image == "":
        genesis_image = constants.DEFAULT_LEAN_GENESIS_GENERATOR_IMAGE
    hash_sig_image = lean_network_params.get("hash_sig_cli_image", "")
    if hash_sig_image == "":
        hash_sig_image = constants.DEFAULT_LEAN_HASH_SIG_CLI_IMAGE
    return genesis_image, hash_sig_image


def _compute_genesis_time(plan, lean_network_params):
    """Resolve GENESIS_TIME.

    Explicit `genesis_time` wins; otherwise we ask a busybox shell for
    `now() + genesis_delay`. Runs on the Kurtosis backend so the result is
    a real clock reading inside the cluster, not the operator's laptop.
    """
    explicit = lean_network_params.get("genesis_time", 0)
    if explicit != 0:
        return str(explicit)
    delay = lean_network_params.get("genesis_delay", 60)
    result = plan.run_sh(
        run="echo -n $(($(date +%s) + {0}))".format(delay),
        description="Computing Lean genesis time",
    )
    return result.output


def _render_validator_config(plan, services_meta, lean_network_params):
    """Render validator-config.yaml from per-node IPs / ports / keys.

    `services_meta` is a list of dicts with keys: name, ip_address, quic_port,
    metrics_port, api_port, privkey, validator_count, is_aggregator.
    """
    template = """shuffle: roundrobin
deployment_mode: kurtosis
config:
  activeEpoch: {{.ActiveEpoch}}
  keyType: "hash-sig"
  attestation_committee_count: {{.AttestationCommitteeCount}}
validators:
{{- range .Validators}}
  - name: "{{.name}}"
    privkey: "{{.privkey}}"
    enrFields:
      ip: "{{.ip}}"
      quic: {{.quic}}
    metricsPort: {{.metricsPort}}
    apiPort: {{.apiPort}}
    isAggregator: {{.isAggregator}}
    count: {{.count}}
{{end}}"""

    validators = []
    for meta in services_meta:
        validators.append(
            {
                "name": meta["name"],
                "privkey": meta["privkey"],
                "ip": meta["ip_address"],
                "quic": meta["quic_port"],
                "metricsPort": meta["metrics_port"],
                "apiPort": meta["api_port"],
                "isAggregator": "true" if meta["is_aggregator"] else "false",
                "count": meta["validator_count"],
            }
        )

    return plan.render_templates(
        config={
            "validator-config.yaml": struct(
                template=template,
                data={
                    "ActiveEpoch": lean_network_params["active_epoch"],
                    "AttestationCommitteeCount": lean_network_params[
                        "attestation_committee_count"
                    ],
                    "Validators": validators,
                },
            ),
        },
        name="lean-validator-config",
        description="Rendering Lean validator-config.yaml",
    )


def _render_initial_config(plan, genesis_time, lean_network_params, total_validators):
    """Render the initial config.yaml that PK's tool consumes.

    PK's tool *rewrites* config.yaml with extra fields after running, but it
    still requires the input to declare GENESIS_TIME, ATTESTATION_COMMITTEE_COUNT,
    ACTIVE_EPOCH, and VALIDATOR_COUNT — every other Lean client reads
    GENESIS_TIME from this file too, so the value must match what we'll embed.
    """
    template = """# Genesis Settings
GENESIS_TIME: {{.GenesisTime}}

# Chain Settings
ATTESTATION_COMMITTEE_COUNT: {{.AttestationCommitteeCount}}

# Key Settings
ACTIVE_EPOCH: {{.ActiveEpoch}}

# Validator Settings
VALIDATOR_COUNT: {{.ValidatorCount}}
"""
    return plan.render_templates(
        config={
            "config.yaml": struct(
                template=template,
                data={
                    "GenesisTime": genesis_time,
                    "AttestationCommitteeCount": lean_network_params[
                        "attestation_committee_count"
                    ],
                    "ActiveEpoch": lean_network_params["active_epoch"],
                    "ValidatorCount": total_validators,
                },
            ),
        },
        name="lean-initial-config",
        description="Rendering Lean initial config.yaml",
    )


def _generate_hash_sig_keys(plan, image, num_validators, active_epoch):
    """Generate XMSS attester+proposer keypairs.

    `hash-sig-cli generate` writes `validator_N_{attester,proposer}_key_{pk,sk}.ssz`
    plus a `validator-keys-manifest.yaml` index. The whole `/hash-sig-keys`
    tree becomes the `lean-hash-sig-keys` artifact mounted at the Lean
    client's `--hash-sig-keys-dir`.
    """
    plan.run_sh(
        run=(
            "mkdir -p {0} && "
            + "hash-sig-cli generate "
            + "--num-validators {1} "
            + "--log-num-active-epochs {2} "
            + "--output-dir {0} "
            + "--export-format ssz"
        ).format(HASH_SIG_DIR, num_validators, active_epoch),
        image=image,
        store=[
            StoreSpec(src=HASH_SIG_DIR, name=HASH_SIG_ARTIFACT_NAME),
        ],
        description="Generating Lean hash-sig validator keys ({0} validators)".format(
            num_validators
        ),
    )
    return HASH_SIG_ARTIFACT_NAME


def _run_genesis_tool(
    plan,
    image,
    validator_config_artifact,
    initial_config_artifact,
):
    """Invoke pk910-leanchain. Outputs config.yaml/validators.yaml/nodes.yaml/genesis.{ssz,json}.

    The tool reads `validator-config.yaml` to figure out per-node ENRs and
    validator counts, and writes the canonical genesis bundle. We mount the
    pre-rendered config.yaml from `--config-output` and let the tool overwrite
    it in place; this lets the tool inject the fork digests and other fields
    it computes itself.
    """
    plan.run_sh(
        run=(
            "mkdir -p {0} && "
            + "cp /input-validator/validator-config.yaml {0}/validator-config.yaml && "
            + "cp /input-config/config.yaml {0}/config.yaml && "
            + "/app/eth-genesis-state-generator leanchain "
            + "--config {0}/config.yaml "
            + "--mass-validators {0}/validator-config.yaml "
            + "--state-output {0}/genesis.ssz "
            + "--json-output {0}/genesis.json "
            + "--nodes-output {0}/nodes.yaml "
            + "--validators-output {0}/validators.yaml "
            + "--config-output {0}/config.yaml"
        ).format(GENESIS_DIR),
        image=image,
        files={
            "/input-validator": validator_config_artifact,
            "/input-config": initial_config_artifact,
        },
        # The genesis tool's outputs are merged with the hash-sig keys and
        # post-processing additions further down before the final artifact
        # is published.
        store=[
            StoreSpec(src=GENESIS_DIR, name="lean-genesis-raw"),
        ],
        description="Running eth-beacon-genesis leanchain",
    )
    return "lean-genesis-raw"


def _post_process(
    plan,
    raw_genesis_artifact,
    hash_sig_artifact,
    validator_config_artifact,
    node_key_artifact,
):
    """Bundle everything Lean clients need into a single mountable artifact.

    Steps:
      * Append GENESIS_VALIDATORS to config.yaml using the dual-key
        manifest emitted by hash-sig-cli (attester_key_pubkey_hex +
        proposer_key_pubkey_hex per validator).
      * Render annotated_validators.yaml mapping node names to validator
        indices and their `_attester_` / `_proposer_` privkey file basenames
        (ethlambda, lantern, and grandine all parse this exact filename
        convention to route keys to attestation vs proposal slots).
      * Copy the per-node P2P keys (`<node>.key`) into the same artifact so
        every client just mounts `/network-configs` and reads everything it
        needs from one place.

    Implemented in shell + yq inside a single busybox-style helper because
    Starlark has no yaml/json libs.
    """
    return plan.run_sh(
        run="""
            set -eu
            mkdir -p /out
            cp /raw/* /out/
            cp /vc/validator-config.yaml /out/
            cp /node-keys/*.key /out/

            # Append GENESIS_VALIDATORS to config.yaml (dual-key layout).
            manifest=/hash-sig/validator-keys-manifest.yaml
            n=$(yq eval '.validators | length' "$manifest")
            printf '\\n# Genesis validator public keys (post-quantum hash-sig)\\nGENESIS_VALIDATORS:\\n' >> /out/config.yaml
            i=0
            while [ "$i" -lt "$n" ]; do
                ah=$(yq eval ".validators[$i].attester_key_pubkey_hex" "$manifest" | sed 's/^0x//')
                ph=$(yq eval ".validators[$i].proposer_key_pubkey_hex" "$manifest" | sed 's/^0x//')
                printf '  - attestation_pubkey: "%s"\\n    proposal_pubkey: "%s"\\n' "$ah" "$ph" >> /out/config.yaml
                i=$((i + 1))
            done

            # Render annotated_validators.yaml from validators.yaml (PK output)
            # joined with the manifest. Each validator index gets two rows
            # (attester + proposer) so clients can route by filename.
            : > /out/annotated_validators.yaml
            for node in $(yq eval 'keys | .[]' /out/validators.yaml); do
                printf '%s:\\n' "$node" >> /out/annotated_validators.yaml
                indices=$(yq eval ".\\"$node\\" | .[]" /out/validators.yaml)
                if [ -z "$indices" ]; then
                    printf '  []\\n' >> /out/annotated_validators.yaml
                    continue
                fi
                for idx in $indices; do
                    ah=$(yq eval ".validators[$idx].attester_key_pubkey_hex" "$manifest" | sed 's/^0x//')
                    ph=$(yq eval ".validators[$idx].proposer_key_pubkey_hex" "$manifest" | sed 's/^0x//')
                    printf '  - index: %s\\n    pubkey_hex: %s\\n    privkey_file: validator_%s_attester_key_sk.ssz\\n' "$idx" "$ah" "$idx" >> /out/annotated_validators.yaml
                    printf '  - index: %s\\n    pubkey_hex: %s\\n    privkey_file: validator_%s_proposer_key_sk.ssz\\n' "$idx" "$ph" "$idx" >> /out/annotated_validators.yaml
                done
            done
        """,
        # mikefarah/yq image ships yq + busybox; we don't need anything else.
        image="mikefarah/yq:4",
        files={
            "/raw": raw_genesis_artifact,
            "/hash-sig": hash_sig_artifact,
            "/vc": validator_config_artifact,
            "/node-keys": node_key_artifact,
        },
        store=[
            StoreSpec(src="/out", name=GENESIS_ARTIFACT_NAME),
        ],
        description="Post-processing Lean genesis (GENESIS_VALIDATORS + annotated_validators.yaml)",
    ).files_artifacts[0]


def generate(plan, services_meta, lean_network_params, node_key_artifact):
    """Top-level entrypoint.

    Args:
        plan: Kurtosis plan.
        services_meta: list of dicts (one per node) with: name, ip_address,
            quic_port, metrics_port, api_port, privkey (hex string),
            validator_count, is_aggregator. The caller (lean_launcher) builds
            this list after Kurtosis has assigned IPs to the placeholder
            services.
        lean_network_params: validated `lean_network_params` block.
        node_key_artifact: files artifact holding `<node>.key` ASCII-hex P2P
            secrets (one per node).

    Returns:
        struct(genesis_artifact = <name>, hash_sig_artifact = <name>,
               genesis_time = <unix seconds string>).
    """
    total_validators = 0
    for meta in services_meta:
        total_validators += meta["validator_count"]

    if total_validators < 1:
        fail(
            "Lean genesis requires at least one validator across all "
            "lean_participants (got 0)."
        )

    genesis_image, hash_sig_image = _resolve_images(lean_network_params)
    genesis_time = _compute_genesis_time(plan, lean_network_params)

    hash_sig_artifact = _generate_hash_sig_keys(
        plan,
        hash_sig_image,
        total_validators,
        lean_network_params["active_epoch"],
    )

    validator_config_artifact = _render_validator_config(
        plan,
        services_meta,
        lean_network_params,
    )

    initial_config_artifact = _render_initial_config(
        plan,
        genesis_time,
        lean_network_params,
        total_validators,
    )

    raw_genesis_artifact = _run_genesis_tool(
        plan,
        genesis_image,
        validator_config_artifact,
        initial_config_artifact,
    )

    final_artifact = _post_process(
        plan,
        raw_genesis_artifact,
        hash_sig_artifact,
        validator_config_artifact,
        node_key_artifact,
    )

    return struct(
        genesis_artifact=final_artifact,
        hash_sig_artifact=hash_sig_artifact,
        genesis_time=genesis_time,
        total_validators=total_validators,
    )
