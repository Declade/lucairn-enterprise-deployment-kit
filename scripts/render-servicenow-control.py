#!/usr/bin/env python3
"""Render an inert Slice 3 Compose assembly; never starts containers.

OFF (default) runs ordinary `docker compose config`, without control inputs.
ON requires an explicit private subnet, two interface IPs, existing bootstrap
credentials and the operator's existing sanitizer YAML. It writes an enabled
YAML copy into a NEW output directory; the source file is never rewritten.
This is an assembly tool, deliberately unreferenced by bin/lucairn and releases.
Requires PyYAML for ON validation. Live process/VM hardening belongs to K3.
"""

import argparse
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
FILES = ("docker-compose.customer.yml", "docker-compose.self-hosted.yml",
         "docker-compose.self-hosted-byok.yml")
COUNTS = {"customer": 1, "self-hosted": 2, "self-hosted-byok": 3}
NETWORK = "servicenow-control"


class Invalid(Exception):
    pass


def nonempty_path(value):
    if value == "":
        raise argparse.ArgumentTypeError("path must not be empty")
    return Path(value)


def private_network(subnet, gateway, sanitizer):
    network = ipaddress.IPv4Network(subnet, strict=True)
    private = tuple(map(ipaddress.IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))
    addresses = [ipaddress.IPv4Address(value) for value in (gateway, sanitizer)]
    if not any(network.subnet_of(block) for block in private):
        raise Invalid()
    if network.prefixlen > 29 or addresses[0] == addresses[1]:
        raise Invalid()
    for address in addresses:
        # Docker's implicit bridge gateway is the first usable address.
        if address not in network or address in (network.network_address,
                network.broadcast_address, network.network_address + 1):
            raise Invalid()
    return network


def compose(args, env, extra=()):
    command = ["docker", "compose", "--env-file", str(args.env_file.resolve()),
               "--project-directory", str(ROOT), "--project-name", args.project_name]
    for file in FILES[:COUNTS[args.path]]:
        command += ["-f", str(ROOT / file)]
    for file in extra:
        command += ["-f", str(file)]
    result = subprocess.run([*command, "config"], env=env, capture_output=True, timeout=30)
    if result.returncode:
        # Compose diagnostics can include interpolated environment; never echo them.
        raise Invalid()
    return result.stdout


def validate_render(rendered, ordinary, network, addresses, material, config):
    if rendered["networks"][NETWORK].get("internal") is not True:
        raise Invalid()
    if rendered["networks"][NETWORK]["ipam"]["config"] != [{"subnet": str(network)}]:
        raise Invalid()
    members = {name for name, service in rendered["services"].items()
               if NETWORK in service.get("networks", {})}
    if members != {"gateway", "sanitizer"}:
        raise Invalid()
    for role, address in zip(("gateway", "sanitizer"), addresses):
        service = rendered["services"][role]
        before = ordinary["services"][role]
        attachment = service["networks"][NETWORK]
        if attachment.get("ipv4_address") != address or attachment.get("aliases") != [role + ".servicenow-control"]:
            raise Invalid()
        if service.get("ports", []) != before.get("ports", []):
            raise Invalid()
        if service.get("ulimits", {}).get("core") != {"soft": 0, "hard": 0}:
            raise Invalid()
        if (service.get("scale") != 1 or service.get("deploy", {}).get("replicas") != 1 or
                service.get("deploy", {}).get("update_config", {}).get("order") != "stop-first" or
                not service.get("container_name")):
            raise Invalid()
        if {key: value for key, value in service["networks"].items() if key != NETWORK} != before["networks"]:
            raise Invalid()
        mounts = [mount for mount in service["volumes"]
                  if mount["target"].startswith("/run/secrets/servicenow-control")]
        if len(mounts) != 1:
            raise Invalid()
        mount = mounts[0]
        if (mount["source"] != str(material / role) or
                mount["target"] != "/run/secrets/servicenow-control/" + role or
                mount.get("read_only") is not True or
                mount.get("bind", {}).get("create_host_path") is not False):
            raise Invalid()
        # Retain the installation's main-channel transport variables exactly.
        for key, value in before.get("environment", {}).items():
            if key.startswith("DSA_MTLS_") or key == "SANITIZER_URL":
                if service["environment"].get(key) != value:
                    raise Invalid()
    gateway = rendered["services"]["gateway"]
    if gateway["environment"].get("GOTRACEBACK") != "none":
        raise Invalid()
    sanitizer = rendered["services"]["sanitizer"]
    config_mount = [mount for mount in sanitizer["volumes"] if mount["target"] == "/config/config.yaml"]
    if (len(config_mount) != 1 or config_mount[0]["source"] != str(config) or
            config_mount[0].get("read_only") is not True or
            sanitizer["environment"].get("SANITIZER_CONFIG_PATH") != "/config/config.yaml"):
        raise Invalid()


def render(args):
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,62}", args.project_name):
        raise Invalid()
    env = dict(os.environ)
    ordinary = compose(args, env)
    if args.mode == "off":
        return ordinary
    import yaml
    network = private_network(args.subnet, args.gateway_ip, args.sanitizer_ip)
    if not all((args.cert_directory, args.sanitizer_config, args.output_directory)):
        raise Invalid()
    cert_directory = args.cert_directory.absolute()
    if any(path.is_symlink() for path in (cert_directory, *cert_directory.parents)):
        raise Invalid()
    spec = importlib.util.spec_from_file_location("control_bootstrap", ROOT / "scripts/bootstrap-servicenow-control.py")
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    try:
        bootstrap.custody(cert_directory, 0o700, os.geteuid(), os.getegid(), True)
        bootstrap.validate(cert_directory / "material", args.workload_uid, args.workload_gid)
    except bootstrap.Invalid:
        raise Invalid() from None
    source = yaml.safe_load(args.sanitizer_config.read_text())
    if not isinstance(source, dict) or not isinstance(source.get("sanitizer"), dict):
        raise Invalid()
    block = source["sanitizer"].setdefault("servicenow_instance_path", {})
    if not isinstance(block, dict):
        raise Invalid()
    block = source["sanitizer"]["servicenow_instance_path"] = dict(block)
    block.update(enabled=True, control_bind_address=args.sanitizer_ip,
                 control_peer_url="https://gateway.servicenow-control:18443",
                 control_ca_cert="/run/secrets/servicenow-control/sanitizer/ca.crt",
                 control_tls_cert="/run/secrets/servicenow-control/sanitizer/tls.crt",
                 control_tls_key="/run/secrets/servicenow-control/sanitizer/tls.key",
                 control_expected_peer_dns="gateway.servicenow-control")
    output = args.output_directory.absolute()
    output.mkdir(mode=0o700)  # Never overwrite a prior render or another session.
    config = output / "sanitizer.yaml"
    overlay = output / "control.compose.json"
    try:
        config.write_text(yaml.safe_dump(source, sort_keys=False))
        config.chmod(0o600)
        os.chown(config, args.workload_uid, args.workload_gid)
        material = cert_directory / "material"
        env.update(SERVICENOW_CONTROL_SUBNET=str(network),
                   SERVICENOW_CONTROL_GATEWAY_IP=args.gateway_ip,
                   SERVICENOW_CONTROL_SANITIZER_IP=args.sanitizer_ip,
                   SERVICENOW_CONTROL_MATERIAL=str(material),
                   SERVICENOW_CONTROL_SANITIZER_CONFIG=str(config))
        # Resolve interpolation into an overlay that can be reviewed independently.
        template = (ROOT / "docker-compose.servicenow-control.yml").read_text()
        env["COMPOSE_PROJECT_NAME"] = args.project_name
        template = re.sub(r"\$\{([A-Z0-9_]+)(?::\?[^}]*)?\}",
                          lambda match: json.dumps(env[match[1]])[1:-1], template)
        overlay.write_text(json.dumps(yaml.safe_load(template), indent=2) + "\n")
        overlay.chmod(0o600)
        result = compose(args, env, (overlay,))
        validate_render(yaml.safe_load(result), yaml.safe_load(ordinary), network,
                        (args.gateway_ip, args.sanitizer_ip), material, config)
        return result
    except BaseException:
        config.unlink(missing_ok=True)
        overlay.unlink(missing_ok=True)
        output.rmdir()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("off", "on"), default="off")
    parser.add_argument("--path", choices=COUNTS, default="customer")
    parser.add_argument("--env-file", type=nonempty_path, required=True)
    parser.add_argument("--project-name", required=True)
    parser.add_argument("--subnet", default="")
    parser.add_argument("--gateway-ip", default="")
    parser.add_argument("--sanitizer-ip", default="")
    parser.add_argument("--cert-directory", type=nonempty_path)
    parser.add_argument("--sanitizer-config", type=nonempty_path)
    parser.add_argument("--output-directory", type=nonempty_path)
    parser.add_argument("--workload-uid", type=int, default=10001)
    parser.add_argument("--workload-gid", type=int, default=10001)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        result = render(args)
    except Exception:
        print("control compose render refused", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
