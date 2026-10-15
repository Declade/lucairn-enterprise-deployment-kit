"""Exercise Linux branches on any host; no Docker daemon or Linux tools needed.

The integration simulation uses real files, OpenSSL and Compose, but mocks the
Linux ACL namespace absent on macOS. It is not a Linux kernel/filesystem proof.
"""

import copy
import errno
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bootstrap = load("portable_bootstrap", "bootstrap-servicenow-control.py")
renderer = load("portable_renderer", "render-servicenow-control.py")


class PortabilityTests(unittest.TestCase):
    def test_linux_acl_absent_unsupported_present_and_unreadable(self):
        missing = OSError(errno.ENODATA, "private diagnostic")
        for names in ([], ["user.unrelated"]):
            with self.subTest(names=names), mock.patch.object(sys, "platform", "linux"), \
                    mock.patch.object(os, "listxattr", create=True, return_value=names), \
                    mock.patch.object(os, "getxattr", create=True, side_effect=missing) as get:
                bootstrap.check_acl(Path("synthetic"))
                self.assertEqual(2, get.call_count)
        for operation in ("listxattr", "getxattr"):
            for number in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENODATA,
                           errno.EACCES, errno.EIO, errno.ENOENT):
                with self.subTest(operation=operation, errno=number), \
                        mock.patch.object(sys, "platform", "linux"), \
                        mock.patch.object(os, "listxattr", create=True, return_value=[]), \
                        mock.patch.object(os, "getxattr", create=True, side_effect=missing), \
                        mock.patch.object(os, operation, create=True, side_effect=OSError(number, "private diagnostic")):
                    if number in (errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENODATA):
                        bootstrap.check_acl(Path("synthetic"))
                    else:
                        with self.assertRaises(bootstrap.Invalid) as error:
                            bootstrap.check_acl(Path("synthetic"))
                        self.assertEqual("acl_check_unavailable", error.exception.reason)
        for name in ("system.posix_acl_access", "system.posix_acl_default"):
            # Even an attribute not returned by listxattr must be rejected.
            def get_acl(path, key, **kwargs):
                if key == name:
                    return b"acl"
                raise missing

            with self.subTest(acl=name), mock.patch.object(sys, "platform", "linux"), \
                    mock.patch.object(os, "listxattr", create=True, return_value=[]), \
                    mock.patch.object(os, "getxattr", create=True, side_effect=get_acl):
                with self.assertRaises(bootstrap.Invalid) as error:
                    bootstrap.check_acl(Path("synthetic"))
                self.assertEqual("custody", error.exception.reason)

    def test_refusal_codes_are_allowlisted_and_do_not_echo_exception_or_args(self):
        private = "/synthetic/private/path?token=DO_NOT_ECHO"
        for module, function, argv, prefix in (
                (renderer, "render", ["render", "--env-file", private, "--project-name", "synthetic"],
                 "control compose render refused: "),
                (bootstrap, "bootstrap", ["bootstrap", private],
                 "control certificate bootstrap refused: ")):
            failures = [(module.Invalid(reason), reason) for reason in module.REASONS]
            failures += [(module.Invalid(private), "validation"),
                         (PermissionError(private), "custody"), (ValueError(private), "validation")]
            for failure, reason in failures:
                with self.subTest(script=function, reason=reason), \
                        mock.patch.object(module, function, side_effect=failure), \
                        mock.patch.object(sys, "argv", argv), \
                        mock.patch.object(sys, "stderr", new_callable=io.StringIO) as stderr:
                    self.assertEqual(1, module.main())
                    self.assertEqual(prefix + reason + "\n", stderr.getvalue())
            with mock.patch.object(sys, "argv", [*argv, "--workload-uid", private]), \
                    mock.patch.object(sys, "stderr", new_callable=io.StringIO) as stderr:
                with self.assertRaises(SystemExit) as error:
                    module.main()
                self.assertEqual(2, error.exception.code)
                self.assertEqual(prefix + "args\n", stderr.getvalue())

    def test_compose_failures_and_timeouts_have_safe_code(self):
        args = SimpleNamespace(env_file=Path("synthetic"), path="customer", project_name="synthetic")
        for failure in (FileNotFoundError("private path"),
                        subprocess.TimeoutExpired(["private command"], 30)):
            with self.subTest(failure=type(failure)), \
                    mock.patch.object(subprocess, "run", side_effect=failure):
                with self.assertRaises(renderer.Invalid) as error:
                    renderer.compose(args, {})
                self.assertEqual("compose_failed", error.exception.reason)
        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, b"private stdout", b"private stderr")):
            with self.assertRaises(renderer.Invalid) as error:
                renderer.compose(args, {})
            self.assertEqual("compose_failed", error.exception.reason)

    def test_linux_branch_bootstrap_and_renderer_with_legacy_compose_output(self):
        scratch = str(Path(tempfile.gettempdir()).resolve())
        with tempfile.TemporaryDirectory(prefix="k1-linux-branches-", dir=scratch) as name:
            base = Path(name)
            env_file = ROOT / "tests/fixtures/servicenow-control/off/synthetic.env.fixture"
            config = base / "source.yaml"
            config.write_text("sanitizer: {}\n")
            args = SimpleNamespace(mode="on", path="customer", env_file=env_file,
                project_name="k1-linux-branches", subnet="172.30.251.0/29",
                gateway_ip="172.30.251.2", sanitizer_ip="172.30.251.3",
                cert_directory=base / "certs", sanitizer_config=config,
                output_directory=base / "output", workload_uid=os.getuid(), workload_gid=os.getgid())
            real_run = subprocess.run

            def legacy_run(command, **kwargs):
                # Compose on the CI image omits false create_host_path values.
                self.assertNotIn("/bin/ls", command)
                result = real_run(command, **kwargs)
                if command[:2] == ["docker", "compose"] and result.returncode == 0:
                    parsed = yaml.safe_load(result.stdout)
                    for service in parsed["services"].values():
                        for mount in service.get("volumes", []):
                            if (mount.get("bind") or {}).get("create_host_path") is False:
                                del mount["bind"]["create_host_path"]
                                if not mount["bind"]:
                                    del mount["bind"]
                    result.stdout = yaml.safe_dump(parsed).encode()
                return result

            with mock.patch.object(sys, "platform", "linux"), \
                    mock.patch.object(os, "listxattr", create=True, return_value=[]), \
                    mock.patch.object(os, "getxattr", create=True, side_effect=OSError(errno.ENODATA, "absent")), \
                    mock.patch.object(subprocess, "run", side_effect=legacy_run):
                bootstrap.bootstrap(args.cert_directory, args.workload_uid, args.workload_gid)
                bootstrap.bootstrap(args.cert_directory, args.workload_uid, args.workload_gid)
                rendered = yaml.safe_load(renderer.render(args))
                for role in ("gateway", "sanitizer"):
                    for mount in rendered["services"][role]["volumes"]:
                        if ("/servicenow-control/" in mount["target"] or
                                (role == "sanitizer" and mount["target"] == "/config/config.yaml")):
                            self.assertIs(mount["bind"]["create_host_path"], False)
                self.assertEqual(0o600, (args.output_directory / "sanitizer.yaml").stat().st_mode & 0o777)
                self.assertEqual(os.getuid(), (args.output_directory / "sanitizer.yaml").stat().st_uid)
                ordinary = yaml.safe_load(renderer.compose(args, dict(os.environ)))
                for bad in (True, "false", None):
                    altered = copy.deepcopy(rendered)
                    mount = next(m for m in altered["services"]["gateway"]["volumes"]
                                 if m["target"] == "/run/secrets/servicenow-control/gateway")
                    mount["bind"] = {"create_host_path": bad}
                    with self.subTest(bad_create=bad), self.assertRaises(renderer.Invalid):
                        renderer.validate_render(altered, ordinary,
                            renderer.private_network(args.subnet, args.gateway_ip, args.sanitizer_ip),
                            (args.gateway_ip, args.sanitizer_ip), args.cert_directory / "material",
                            args.output_directory / "sanitizer.yaml")
            overlay = json.loads((args.output_directory / "control.compose.json").read_text())
            renderer.validate_overlay(overlay)
            del overlay["services"]["gateway"]["volumes"][0]["bind"]
            with self.assertRaises(renderer.Invalid):
                renderer.validate_overlay(overlay)
        print("Linux branch simulation: bootstrap fresh/rerun + ON render passed; "
              "mocked ACL namespace, legacy Compose false omission, native uid/gid")


if __name__ == "__main__":
    unittest.main()
