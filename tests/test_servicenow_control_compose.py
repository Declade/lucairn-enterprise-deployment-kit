"""Compose config integration only: no images, daemon, listeners or real services."""

import copy
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import yaml


SCRATCH = "/private/tmp" if Path("/private/tmp").is_dir() else str(Path(tempfile.gettempdir()).resolve())

ROOT = Path(os.environ.get("K1_COMPOSE_ROOT", Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location("control_render", ROOT / "scripts/render-servicenow-control.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class ComposeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="k1-compose-", dir=SCRATCH)
        cls.base = Path(cls.scratch.name)
        cls.cert = cls.base / "certs"
        result = subprocess.run(["python3", str(ROOT / "scripts/bootstrap-servicenow-control.py"),
                                 str(cls.cert), "--workload-uid", str(os.geteuid()),
                                 "--workload-gid", str(os.getegid())], capture_output=True, timeout=20)
        if result.returncode:
            raise AssertionError("synthetic bootstrap failed")
        required = set(re.findall(r"\$\{([A-Z0-9_]+):\?", "".join(
            (ROOT / file).read_text() for file in renderer.FILES)))
        cls.env = cls.base / "synthetic.env"
        cls.env.write_text("".join(key + "=k1-synthetic\n" for key in sorted(required)))
        cls.config = cls.base / "source.yaml"
        cls.source = {"gateway": {"unchanged": "synthetic"}, "sanitizer": {
            "keep": [False, 17, "synthetic"], "servicenow_instance_path": {
                "enabled": False, "assertion_posture": "block", "entropy_id_release": "retain",
                "typed_text_threshold": 2000, "servicenow_mcp_server": "synthetic"}}}
        cls.config.write_text(yaml.safe_dump(cls.source))

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="k1-render-", dir=SCRATCH)
        self.output = Path(self.temp.name) / "output"

    def tearDown(self):
        self.temp.cleanup()

    def invoke(self, path="customer", mode="on", **changes):
        options = {"mode": mode, "path": path, "env-file": self.env,
                   "project-name": "k1-synthetic", "subnet": "172.30.251.0/29",
                   "gateway-ip": "172.30.251.2", "sanitizer-ip": "172.30.251.3",
                   "cert-directory": self.cert, "sanitizer-config": self.config,
                   "output-directory": self.output, "workload-uid": os.geteuid(),
                   "workload-gid": os.getegid()}
        options.update(changes)
        result = subprocess.run(["python3", str(ROOT / "scripts/render-servicenow-control.py"),
                                 *[str(value) for key, value in options.items()
                                   if value is not None
                                   for value in ("--" + key, value)]],
                                capture_output=True, timeout=40)
        return result

    def successful(self, path="customer"):
        result = self.invoke(path=path)
        self.assertEqual(0, result.returncode, result.stderr.decode())
        return yaml.safe_load(result.stdout)

    def test_on_all_customer_self_hosted_and_byok_paths(self):
        for path in renderer.COUNTS:
            with self.subTest(path=path):
                rendered = self.successful(path)
                self.assertIn("gateway", rendered["services"])
                self.assertTrue((self.output / "control.compose.json").is_file())
                shutil.rmtree(self.output)

    def test_private_network_fixed_binds_aliases_and_only_two_members(self):
        rendered = self.successful()
        network = rendered["networks"]["servicenow-control"]
        self.assertIs(network["internal"], True)
        self.assertEqual([{"subnet": "172.30.251.0/29"}], network["ipam"]["config"])
        members = {role for role, service in rendered["services"].items()
                   if "servicenow-control" in service.get("networks", {})}
        self.assertEqual({"gateway", "sanitizer"}, members)
        for role, address in (("gateway", "172.30.251.2"), ("sanitizer", "172.30.251.3")):
            self.assertEqual({"ipv4_address": address, "aliases": [role + ".servicenow-control"]},
                             rendered["services"][role]["networks"]["servicenow-control"])
        self.assertEqual("172.30.251.2", rendered["services"]["gateway"]["environment"][
            "GATEWAY_SERVICENOW_CONTROL_BIND_ADDRESS"])

    def test_leaf_only_read_only_mounts_without_host_creation(self):
        rendered = self.successful()
        for role in ("gateway", "sanitizer"):
            mounts = rendered["services"][role]["volumes"]
            control = [mount for mount in mounts if "/servicenow-control/" in mount["target"]]
            self.assertEqual(1, len(control))
            self.assertEqual(str(self.cert / "material" / role), control[0]["source"])
            self.assertEqual("/run/secrets/servicenow-control/" + role, control[0]["target"])
            self.assertIs(control[0]["read_only"], True)
            self.assertIs(control[0]["bind"]["create_host_path"], False)
            self.assertEqual({"ca.crt", "tls.crt", "tls.key"},
                             {path.name for path in Path(control[0]["source"]).iterdir()})
            self.assertFalse(any("operator" in mount["source"] for mount in mounts))

    def test_exact_frozen_settings_and_preserved_source_yaml(self):
        rendered = self.successful()
        env = rendered["services"]["gateway"]["environment"]
        self.assertEqual("true", env["GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED"])
        expected = {"BIND_ADDRESS": "172.30.251.2", "PEER_URL": "https://sanitizer.servicenow-control:18444",
                    "CA_CERT": "/run/secrets/servicenow-control/gateway/ca.crt",
                    "TLS_CERT": "/run/secrets/servicenow-control/gateway/tls.crt",
                    "TLS_KEY": "/run/secrets/servicenow-control/gateway/tls.key",
                    "EXPECTED_PEER_DNS": "sanitizer.servicenow-control"}
        self.assertEqual(expected, {key.removeprefix("GATEWAY_SERVICENOW_CONTROL_"): value
                                  for key, value in env.items() if key.startswith("GATEWAY_SERVICENOW_CONTROL_")})
        generated = yaml.safe_load((self.output / "sanitizer.yaml").read_text())
        info = (self.output / "sanitizer.yaml").stat()
        self.assertEqual(0o600, info.st_mode & 0o777)
        self.assertEqual((os.geteuid(), os.getegid()), (info.st_uid, info.st_gid))
        expected_source = copy.deepcopy(self.source)
        expected_source["sanitizer"]["servicenow_instance_path"].update({
            "enabled": True, "control_bind_address": "172.30.251.3",
            "control_peer_url": "https://gateway.servicenow-control:18443",
            "control_ca_cert": "/run/secrets/servicenow-control/sanitizer/ca.crt",
            "control_tls_cert": "/run/secrets/servicenow-control/sanitizer/tls.crt",
            "control_tls_key": "/run/secrets/servicenow-control/sanitizer/tls.key",
            "control_expected_peer_dns": "gateway.servicenow-control"})
        self.assertEqual(expected_source, generated)
        self.assertEqual(self.source, yaml.safe_load(self.config.read_text()))
        self.assertFalse(any(key.startswith("SERVICENOW") or key.startswith("SANITIZER_SERVICENOW")
                             for key in rendered["services"]["sanitizer"]["environment"]))

    def test_core_zero_traceback_and_single_owner_replacement_render(self):
        rendered = self.successful()
        for role in ("gateway", "sanitizer"):
            self.assertEqual({"soft": 0, "hard": 0}, rendered["services"][role]["ulimits"]["core"])
        gateway = rendered["services"]["gateway"]
        self.assertEqual("none", gateway["environment"]["GOTRACEBACK"])
        self.assertEqual(1, gateway["scale"])
        self.assertEqual(1, gateway["deploy"]["replicas"])
        self.assertEqual("stop-first", gateway["deploy"]["update_config"]["order"])
        self.assertEqual("k1-synthetic-gateway-servicenow-control", gateway["container_name"])

    def test_no_published_control_ports_or_main_channel_mesh_change(self):
        on = self.successful()
        off = self.invoke(mode="off")
        self.assertEqual(0, off.returncode)
        ordinary = yaml.safe_load(off.stdout)
        for role in ("gateway", "sanitizer"):
            before, after = ordinary["services"][role], on["services"][role]
            self.assertEqual(before.get("ports", []), after.get("ports", []))
            self.assertFalse(any(int(port["target"]) in (18443, 18444) for port in after.get("ports", [])))
            self.assertEqual(before["networks"], {key: value for key, value in after["networks"].items()
                                                 if key != "servicenow-control"})
            self.assertEqual({key: value for key, value in before["environment"].items() if "MTLS" in key},
                             {key: value for key, value in after["environment"].items() if "MTLS" in key})
        self.assertEqual("http://sanitizer:8086", on["services"]["gateway"]["environment"]["SANITIZER_URL"])

    def test_off_ignores_control_inputs_and_creates_no_artifact(self):
        for path in renderer.COUNTS:
            with self.subTest(path=path):
                result = self.invoke(path=path, mode=None, **{
                    "cert-directory": self.base / "missing", "sanitizer-config": self.base / "missing",
                    "gateway-ip": "0.0.0.0", "subnet": "invalid"})
                self.assertEqual(0, result.returncode, result.stderr.decode())
                ordinary = renderer.compose(type("Args", (), {"env_file": self.env,
                    "project_name": "k1-synthetic", "path": path})(), dict(os.environ))
                self.assertEqual(ordinary, result.stdout)
                self.assertNotIn(b"servicenow-control", result.stdout)
                self.assertFalse(self.output.exists())

    def test_invalid_mode_refuses_without_render(self):
        result = self.invoke(mode="invalid")
        self.assertEqual(2, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertFalse(self.output.exists())

    def test_invalid_private_interfaces_refuse_without_render(self):
        cases = [{"gateway-ip": value} for value in
                 ("", "0.0.0.0", "::", "[::]", "*", "127.0.0.1", "8.8.8.8",
                  "169.254.1.2", "172.30.251.0", "172.30.251.1", "172.30.251.7",
                  "172.30.251.3", "172.30.250.2")]
        cases += [{"sanitizer-ip": "0.0.0.0"}, {"subnet": "8.8.8.0/29"},
                  {"subnet": "8.8.8.0/29", "gateway-ip": "8.8.8.2", "sanitizer-ip": "8.8.8.3"},
                  {"subnet": "192.0.2.0/29"}, {"subnet": "172.30.251.2/29"}]
        for changes in cases:
            with self.subTest(changes=changes):
                result = self.invoke(**changes)
                self.assertEqual(1, result.returncode)
                self.assertEqual(b"", result.stdout)
                self.assertFalse(self.output.exists())

    def test_invalid_config_missing_credentials_or_existing_output_refuse(self):
        invalid = self.base / "invalid.yaml"
        invalid.write_text("sanitizer: []\n")
        for changes in ({"cert-directory": self.base / "missing"},
                        {"sanitizer-config": invalid}, {"workload-uid": os.geteuid() + 1}):
            with self.subTest(changes=changes):
                result = self.invoke(**changes)
                self.assertEqual(1, result.returncode)
                self.assertEqual(b"", result.stdout)
                self.assertFalse(self.output.exists())
        self.output.mkdir()
        marker = self.output / "preserve"
        marker.write_text("synthetic")
        result = self.invoke()
        self.assertEqual(1, result.returncode)
        self.assertEqual("synthetic", marker.read_text())

    def test_raw_overlay_missing_required_interpolation_is_invalid_compose(self):
        result = subprocess.run(["docker", "compose", "--env-file", str(self.env),
            "--project-directory", str(ROOT), "--project-name", "k1-synthetic",
            "-f", str(ROOT / renderer.FILES[0]), "-f", str(ROOT / "docker-compose.servicenow-control.yml"),
            "config"], env={key: value for key, value in os.environ.items()
                            if not key.startswith("SERVICENOW_CONTROL_")},
            capture_output=True, timeout=30)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertIn(b"SERVICENOW_CONTROL_", result.stderr)

    def test_unassignable_workload_config_owner_refuses_without_artifact(self):
        args = SimpleNamespace(mode="on", path="customer", env_file=self.env,
            project_name="k1-synthetic", subnet="172.30.251.0/29",
            gateway_ip="172.30.251.2", sanitizer_ip="172.30.251.3",
            cert_directory=self.cert, sanitizer_config=self.config,
            output_directory=self.output, workload_uid=os.geteuid(), workload_gid=os.getegid())
        # An operator unable to assign ownership must not get a successful
        # assembly with an unreadable 0600 config. No root privileges needed.
        with mock.patch.object(renderer.os, "chown", side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                renderer.render(args)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
