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


def _render_validator_config(plan, services_meta, lean_network_params, keys_artifact):
    """Render validator-config.yaml from per-node IPs / ports / keys.

    Two-stage render:

      Stage 1 - `plan.render_templates` produces validator-config.yaml with
        IPs and ports substituted from Kurtosis runtime futures, but the
        privkey field set to a placeholder marker `__PRIVKEY_<node_name>__`.
        Kurtosis's template engine handles the IP futures correctly; trying
        to embed them inside a raw shell heredoc doesn't (the {{kurtosis:...}}
        markers reach the shell before substitution and break sh parsing).

      Stage 2 - `plan.run_sh` reads the placeholders and replaces each one
        with the corresponding key from the lean-node-keys artifact via sed.
        The shell never sees a Kurtosis future, only literal text.

    `services_meta` is a list of dicts with keys: name, ip_address,
    quic_port, metrics_port, api_port, validator_count, is_aggregator.
    """
    template = """shuffle: roundrobin
deployment_mode: kurtosis
config:
  activeEpoch: {{.ActiveEpoch}}
  keyType: "hash-sig"
  attestation_committee_count: {{.AttestationCommitteeCount}}
validators:
{{- range .Validators}}
  - name: "{{.Name}}"
    privkey: "__PRIVKEY_{{.Name}}__"
    enrFields:
      ip: "{{.Ip}}"
      quic: {{.Quic}}
    metricsPort: {{.MetricsPort}}
    apiPort: {{.ApiPort}}
    isAggregator: {{.IsAggregator}}
    count: {{.Count}}
{{end}}"""

    validators = []
    for meta in services_meta:
        validators.append(
            {
                "Name": meta["name"],
                "Ip": meta["ip_address"],
                "Quic": meta["quic_port"],
                "MetricsPort": meta["metrics_port"],
                "ApiPort": meta["api_port"],
                "IsAggregator": "true" if meta["is_aggregator"] else "false",
                "Count": meta["validator_count"],
            }
        )

    template_artifact = plan.render_templates(
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
        name="lean-validator-config-template",
        description="Rendering Lean validator-config.yaml (stage 1, placeholders)",
    )

    # Stage 2: sed each `__PRIVKEY_<name>__` to the contents of the
    # matching `/keys/<name>.key`. Run inside a single shell so we don't
    # have to thread Kurtosis futures through more steps.
    sed_lines = ["set -eu", "mkdir -p /out", "cp /tpl/validator-config.yaml /out/"]
    for meta in services_meta:
        # The privkey file holds a raw 64-char hex string with no surrounding
        # whitespace. Use sed with a `|` delimiter since the key is hex
        # (which never contains `|`) and the placeholder is unique.
        sed_lines.append(
            (
                "key=$(cat /keys/{0}.key) && "
                + "sed -i \"s|__PRIVKEY_{0}__|$key|\" /out/validator-config.yaml"
            ).format(meta["name"])
        )
    sed_script = "\n".join(sed_lines)

    result = plan.run_sh(
        run=sed_script,
        # alpine/openssl already lives in the engine cache from the P2P
        # key generation step and ships busybox sed.
        image="alpine/openssl",
        files={
            "/tpl": template_artifact,
            "/keys": keys_artifact,
        },
        store=[StoreSpec(src="/out/validator-config.yaml", name="lean-validator-config")],
        description="Rendering Lean validator-config.yaml (stage 2, privkey inlining)",
    )
    return result.files_artifacts[0]


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
    # The binary in `blockblaz/hash-sig-cli:latest` is `hashsig` (the image's
    # ENTRYPOINT). Kurtosis's `plan.run_sh` overrides the entrypoint with
    # `sh -c`, so we have to call the binary by its absolute path. It lives
    # at `/usr/local/bin/hashsig`.
    plan.run_sh(
        run=(
            "mkdir -p {0} && "
            + "/usr/local/bin/hashsig generate "
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


def generate_hash_sig_keys(plan, lean_network_params, total_validators):
    """Public wrapper around _generate_hash_sig_keys.

    Exposed so `lean_launcher.launch` can pre-create the hash-sig artifact
    before any service is added. This lets every Lean client mount the keys
    at `initialize()` time (the keys are IP-independent), keeping us inside
    Kurtosis's "one add_service per name" constraint.
    """
    if total_validators < 1:
        fail(
            "Lean genesis requires at least one validator across all "
            + "lean_participants (got 0).",
        )
    _, hash_sig_image = _resolve_images(lean_network_params)
    return _generate_hash_sig_keys(
        plan,
        hash_sig_image,
        total_validators,
        lean_network_params["active_epoch"],
    )


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

    Implemented as a Python script (Starlark has no YAML libs and busybox
    `sh` in common images chokes on heredocs with embedded interpreters).
    The script is rendered as a separate artifact via `render_templates`
    and invoked by a tiny shell wrapper - no heredocs reach `sh`.
    """
    # The script reads the hash-sig manifest, PK's validators.yaml output,
    # and the raw genesis bundle, then writes:
    #   - /out/config.yaml with GENESIS_VALIDATORS appended (dual-key layout)
    #   - /out/annotated_validators.yaml (node_name -> [{index, pubkey_hex,
    #     privkey_file}, ...] with attester + proposer rows per index)
    #   - all other genesis files copied through unchanged
    #   - hash-sig keys bundled into ./hash-sig-keys/
    #   - per-node `<name>.key` libp2p secrets bundled at the top level
    python_source = """import os
import shutil
import yaml

RAW = "/raw"
HASH_SIG = "/hash-sig"
VC = "/vc"
NODE_KEYS = "/node-keys"
OUT = "/out"
MANIFEST = os.path.join(HASH_SIG, "validator-keys-manifest.yaml")


def _as_hex(value):
    # Normalise a pubkey field to a no-0x-prefix lowercase hex string.
    # Even with BaseLoader (which keeps everything as str) we strip the 0x
    # prefix here; int fallback handles unexpected manifest shapes.
    if isinstance(value, int):
        return format(value, "x")
    s = str(value)
    if s.startswith("0x") or s.startswith("0X"):
        s = s[2:]
    return s


def copytree_into(src, dst):
    os.makedirs(dst, exist_ok=True)
    for entry in os.listdir(src):
        s = os.path.join(src, entry)
        d = os.path.join(dst, entry)
        if os.path.isdir(s):
            shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)


# Stage 1: bundle all input artifacts into /out.
os.makedirs(OUT, exist_ok=True)
copytree_into(RAW, OUT)
shutil.copy2(os.path.join(VC, "validator-config.yaml"), OUT)
for f in os.listdir(NODE_KEYS):
    if f.endswith(".key"):
        shutil.copy2(os.path.join(NODE_KEYS, f), OUT)
copytree_into(HASH_SIG, os.path.join(OUT, "hash-sig-keys"))

# Stage 2: append GENESIS_VALIDATORS (dual-key) to config.yaml.
with open(MANIFEST) as f:
    # BaseLoader keeps every scalar as a Python str. We need this for the
    # XMSS pubkey hex fields: YAML 1.1 (PyYAML's default) interprets
    # unquoted `0x...` tokens as integers, which silently drops leading
    # zeros when we format the value back out — clients then reject the
    # config because the pubkey has an odd number of hex digits.
    manifest = yaml.load(f, Loader=yaml.BaseLoader)

gv_lines = ["", "# Genesis validator public keys (post-quantum hash-sig)", "GENESIS_VALIDATORS:"]
for v in manifest["validators"]:
    ah = _as_hex(v["attester_key_pubkey_hex"])
    ph = _as_hex(v["proposer_key_pubkey_hex"])
    gv_lines.append('  - attestation_pubkey: "{0}"'.format(ah))
    gv_lines.append('    proposal_pubkey: "{0}"'.format(ph))
with open(os.path.join(OUT, "config.yaml"), "a") as f:
    f.write("\\n".join(gv_lines) + "\\n")

# Stage 3: render annotated_validators.yaml from validators.yaml + manifest.
with open(os.path.join(OUT, "validators.yaml")) as f:
    # Use BaseLoader too (see manifest load above) for consistency, even
    # though this file has no hex tokens to worry about today.
    assignments = yaml.load(f, Loader=yaml.BaseLoader) or {}

ann_lines = []
for node, indices in assignments.items():
    ann_lines.append("{0}:".format(node))
    if not indices:
        ann_lines.append("  []")
        continue
    for idx in indices:
        v = manifest["validators"][int(idx)]
        ah = _as_hex(v["attester_key_pubkey_hex"])
        ph = _as_hex(v["proposer_key_pubkey_hex"])
        ann_lines.append("  - index: {0}".format(idx))
        ann_lines.append("    pubkey_hex: {0}".format(ah))
        ann_lines.append(
            "    privkey_file: validator_{0}_attester_key_sk.ssz".format(idx)
        )
        ann_lines.append("  - index: {0}".format(idx))
        ann_lines.append("    pubkey_hex: {0}".format(ph))
        ann_lines.append(
            "    privkey_file: validator_{0}_proposer_key_sk.ssz".format(idx)
        )
with open(os.path.join(OUT, "annotated_validators.yaml"), "w") as f:
    f.write("\\n".join(ann_lines) + "\\n")
"""

    script_artifact = plan.render_templates(
        config={
            "post_process.py": struct(template=python_source, data={}),
        },
        name="lean-post-process-script",
        description="Rendering Lean genesis post-process script",
    )

    return plan.run_sh(
        run=(
            "set -eu; "
            + "pip install --quiet --root-user-action=ignore pyyaml; "
            + "python3 /script/post_process.py"
        ),
        image="python:3-alpine",
        files={
            "/raw": raw_genesis_artifact,
            "/hash-sig": hash_sig_artifact,
            "/vc": validator_config_artifact,
            "/node-keys": node_key_artifact,
            "/script": script_artifact,
        },
        store=[
            StoreSpec(src="/out", name=GENESIS_ARTIFACT_NAME),
        ],
        description="Post-processing Lean genesis (GENESIS_VALIDATORS + annotated_validators.yaml)",
    ).files_artifacts[0]


def generate(
    plan,
    services_meta,
    lean_network_params,
    node_key_artifact,
    hash_sig_artifact,
):
    """Top-level entrypoint.

    Args:
        plan: Kurtosis plan.
        services_meta: list of dicts (one per node) with: name, ip_address,
            quic_port, metrics_port, api_port, validator_count, is_aggregator.
            The caller (lean_launcher) builds this list after Kurtosis has
            assigned IPs to the placeholder services.
        lean_network_params: validated `lean_network_params` block.
        node_key_artifact: files artifact holding `<node>.key` ASCII-hex P2P
            secrets (one per node).
        hash_sig_artifact: files artifact holding the XMSS attester+proposer
            keypairs (pre-generated by `generate_hash_sig_keys`).

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
            + "lean_participants (got 0).",
        )

    genesis_image, _ = _resolve_images(lean_network_params)
    genesis_time = _compute_genesis_time(plan, lean_network_params)

    validator_config_artifact = _render_validator_config(
        plan,
        services_meta,
        lean_network_params,
        node_key_artifact,
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
