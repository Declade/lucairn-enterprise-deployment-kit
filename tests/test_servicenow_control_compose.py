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


SCRATCH = str(Path(tempfile.gettempdir()).resolve())

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
                                 str(cls.cert), "--workload-uid", str(os.getuid()),
                                 "--workload-gid", str(os.getgid())], capture_output=True, timeout=20)
        if result.returncode:
            raise AssertionError("synthetic bootstrap failed")
        required = set(re.findall(r"\$\{([A-Z0-9_]+):\?", "".join(
            (ROOT / file).read_text() for file in renderer.FILES)))
        cls.env = cls.base / "synthetic.env"
        # K-C: the operator settings reach the overlay through Compose's own
        # --env-file interpolation (synthetic key/instance/customer ids).
        cls.env.write_text("".join(key + "=k1-synthetic\n" for key in sorted(required)) +
                           "GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED=true\n"
                           "GATEWAY_SERVICENOW_KEY_BINDINGS=k1_key=k1-instance\n"
                           'GATEWAY_SERVICENOW_INSTANCES=[{"id":"k1-instance","base_url":"https://k1.invalid","customer_id":"k1_customer"}]\n')
        cls.login = cls.base / "login"
        cls.login.mkdir(mode=0o700)
        (cls.login / "login.json").write_text("{}")
        (cls.login / "login.json").chmod(0o400)
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
                   "core-ip": "172.30.251.4", "login-directory": self.login,
                   "cert-directory": self.cert, "sanitizer-config": self.config,
                   "output-directory": self.output, "workload-uid": os.getuid(),
                   "workload-gid": os.getgid()}
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
        # K-C: the sidecar carries the core's attachment (shared namespace),
        # at a fixed address and WITHOUT an alias.
        self.assertEqual({"gateway", "sanitizer", "sanitizer-core-sidecar"}, members)
        self.assertEqual({"ipv4_address": "172.30.251.4"},
                         rendered["services"]["sanitizer-core-sidecar"]["networks"]["servicenow-control"])
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
        self.assertEqual((os.getuid(), os.getgid()), (info.st_uid, info.st_gid))
        expected_source = copy.deepcopy(self.source)
        expected_source["sanitizer"]["servicenow_instance_path"].update({
            "enabled": True, "control_wiring_released": True, "control_bind_address": "172.30.251.3",
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
            service = rendered["services"][role]
            self.assertEqual({"soft": 0, "hard": 0}, service["ulimits"]["core"])
            self.assertEqual(1, service["scale"])
            self.assertEqual(1, service["deploy"]["replicas"])
            self.assertEqual("stop-first", service["deploy"]["update_config"]["order"])
            self.assertEqual("k1-synthetic-" + role + "-servicenow-control", service["container_name"])
        gateway = rendered["services"]["gateway"]
        self.assertEqual("none", gateway["environment"]["GOTRACEBACK"])

    def test_core_opt_in_sidecar_attachment_and_login_scope(self):
        # Kit 2.0 K-C: the core runs the kit-servicenow profile with the
        # sanitizer control leaf; the sidecar (whose namespace the core
        # shares) is on the control network at a fixed address with NO alias
        # and holds NO control material; the stored login reaches the gateway
        # only.
        rendered = self.successful()
        services = rendered["services"]
        core, side = services["sanitizer-core"], services["sanitizer-core-sidecar"]
        env = core["environment"]
        self.assertEqual("kit-servicenow", env["LCR_PROFILE"])
        self.assertEqual("none", env["GOTRACEBACK"])
        self.assertEqual("https://gateway.servicenow-control:18443", env["LCR_SERVICENOW_CONTROL_PEER_URL"])
        self.assertEqual({"soft": 0, "hard": 0}, core["ulimits"]["core"])
        control = [m for m in core["volumes"] if m["target"].startswith("/run/secrets/servicenow-control/")]
        self.assertEqual([str(self.cert / "material" / "sanitizer")], [m["source"] for m in control])
        self.assertEqual({"ipv4_address": "172.30.251.4"}, side["networks"]["servicenow-control"])
        self.assertFalse(any("servicenow" in str(m) for m in side.get("volumes", [])))
        holders = sorted(name for name, service in services.items()
                         if any(m["target"] == "/run/secrets/servicenow-login" for m in service.get("volumes", [])))
        self.assertEqual(["gateway"], holders)
        login = next(m for m in services["gateway"]["volumes"] if m["target"] == "/run/secrets/servicenow-login")
        self.assertEqual((str(self.login), True), (login["source"], login["read_only"]))
        gateway_env = services["gateway"]["environment"]
        self.assertEqual("k1_key=k1-instance", gateway_env["GATEWAY_SERVICENOW_KEY_BINDINGS"])
        self.assertEqual("/run/secrets/servicenow-login/login.json", gateway_env["GATEWAY_SERVICENOW_LOGIN_FILE"])
        self.assertEqual("/var/lib/lucairn/servicenow-state", gateway_env["GATEWAY_SERVICENOW_STATE_DIR"])

    def test_renderer_refuses_missing_sanitizer_single_owner_guards(self):
        rendered = self.successful()
        ordinary = yaml.safe_load(self.invoke(mode="off").stdout)
        for guard in ("scale", "container_name", "replicas", "update_config"):
            with self.subTest(guard=guard):
                altered = copy.deepcopy(rendered)
                service = altered["services"]["sanitizer"]
                (service if guard in ("scale", "container_name") else service["deploy"]).pop(guard)
                with self.assertRaises(renderer.Invalid):
                    renderer.validate_render(altered, ordinary,
                        renderer.private_network("172.30.251.0/29", "172.30.251.2", "172.30.251.3"),
                        ("172.30.251.2", "172.30.251.3"), self.cert / "material",
                        self.output / "sanitizer.yaml")

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

    def test_empty_path_arguments_refuse_explicitly_without_render(self):
        for mode in ("off", "on"):
            for option in ("env-file", "cert-directory", "sanitizer-config", "output-directory", "login-directory"):
                with self.subTest(mode=mode, option=option):
                    result = self.invoke(mode=mode, **{option: ""})
                    self.assertEqual(2, result.returncode)
                    self.assertEqual(b"control compose render refused: args\n", result.stderr)
                    self.assertEqual(b"", result.stdout)
                    self.assertFalse(self.output.exists())

    def test_invalid_private_interfaces_refuse_without_render(self):
        cases = [{"gateway-ip": value} for value in
                 ("", "0.0.0.0", "::", "[::]", "*", "127.0.0.1", "8.8.8.8",
                  "169.254.1.2", "172.30.251.0", "172.30.251.1", "172.30.251.7",
                  "172.30.251.3", "172.30.250.2")]
        cases += [{"core-ip": value} for value in ("", "172.30.251.2", "172.30.251.3", "172.30.251.1", "172.30.250.4")]
        cases += [{"sanitizer-ip": "0.0.0.0"}, {"subnet": "8.8.8.0/29"},
                  {"subnet": "8.8.8.0/29", "gateway-ip": "8.8.8.2", "sanitizer-ip": "8.8.8.3", "core-ip": "8.8.8.4"},
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
                        {"sanitizer-config": invalid}, {"workload-uid": os.getuid() + 1}):
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
            gateway_ip="172.30.251.2", sanitizer_ip="172.30.251.3", core_ip="172.30.251.4",
            login_directory=self.login,
            cert_directory=self.cert, sanitizer_config=self.config,
            output_directory=self.output, workload_uid=os.getuid(), workload_gid=os.getgid())
        # An operator unable to assign ownership must not get a successful
        # assembly with an unreadable 0600 config. No root privileges needed.
        with mock.patch.object(renderer.os, "chown", side_effect=PermissionError):
            with self.assertRaises(PermissionError):
                renderer.render(args)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
