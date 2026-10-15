"""Bounded source mutants in disposable copies; never changes repo permissions."""

import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest


SCRATCH = "/private/tmp" if Path("/private/tmp").is_dir() else str(Path(tempfile.gettempdir()).resolve())

ROOT = Path(__file__).resolve().parents[1]


class MutantTests(unittest.TestCase):
    def test_compose_protective_mutants_turn_red(self):
        overlay = "docker-compose.servicenow-control.yml"
        script = "scripts/render-servicenow-control.py"
        mutations = [
            ("internal network", overlay, "internal: true", "internal: false",
             "test_private_network_fixed_binds_aliases_and_only_two_members"),
            ("literal interface bind", overlay,
             'GATEWAY_SERVICENOW_CONTROL_BIND_ADDRESS: "${SERVICENOW_CONTROL_GATEWAY_IP:?explicit private interface required}"',
             'GATEWAY_SERVICENOW_CONTROL_BIND_ADDRESS: "0.0.0.0"',
             "test_private_network_fixed_binds_aliases_and_only_two_members"),
            ("leaf custody mount", overlay, '}/gateway"', '}/operator"',
             "test_leaf_only_read_only_mounts_without_host_creation"),
            ("read only leaf", overlay, "read_only: true", "read_only: false",
             "test_leaf_only_read_only_mounts_without_host_creation"),
            ("no published control port", overlay, "    scale: 1", '    ports: ["18443:18443"]\n    scale: 1',
             "test_no_published_control_ports_or_main_channel_mesh_change"),
            ("main mesh unchanged", overlay, '      GOTRACEBACK: none',
             '      SANITIZER_URL: "https://sanitizer:8086"\n      GOTRACEBACK: none',
             "test_no_published_control_ports_or_main_channel_mesh_change"),
            ("core zero", overlay, "soft: 0", "soft: 1",
             "test_core_zero_traceback_and_single_owner_replacement_render"),
            ("Go traceback", overlay, "GOTRACEBACK: none", "GOTRACEBACK: all",
             "test_core_zero_traceback_and_single_owner_replacement_render"),
            ("one replica", overlay, "replicas: 1", "replicas: 2",
             "test_core_zero_traceback_and_single_owner_replacement_render"),
            ("stop first", overlay, "order: stop-first", "order: start-first",
             "test_core_zero_traceback_and_single_owner_replacement_render"),
            ("fixed name blocks scale", overlay,
             '    container_name: "${COMPOSE_PROJECT_NAME}-gateway-servicenow-control"\n', "",
             "test_core_zero_traceback_and_single_owner_replacement_render"),
            ("sanitizer YAML switch", script, "block.update(enabled=True", "block.update(enabled=False",
             "test_exact_frozen_settings_and_preserved_source_yaml"),
            ("workload config ownership", script, "os.chown(config, args.workload_uid, args.workload_gid)", "pass",
             "test_unassignable_workload_config_owner_refuses_without_artifact"),
            ("exact peer identity", overlay, "EXPECTED_PEER_DNS: sanitizer.servicenow-control",
             "EXPECTED_PEER_DNS: gateway.servicenow-control",
             "test_exact_frozen_settings_and_preserved_source_yaml"),
            ("OFF selection", script, 'if args.mode == "off":', "if False:",
             "test_off_ignores_control_inputs_and_creates_no_artifact"),
            ("private subnet", script, "if not any(network.subnet_of(block) for block in private):", "if False:",
             "test_invalid_private_interfaces_refuse_without_render"),
            ("distinct interface IPs", script, "addresses[0] == addresses[1]", "False",
             "test_invalid_private_interfaces_refuse_without_render"),
            ("empty path argument", script, 'if value == "":', "if False:",
             "test_empty_path_arguments_refuse_explicitly_without_render"),
            ("bind subnet membership", script, "if address not in network or address in (network.network_address,",
             "if False and address in (network.network_address,",
             "test_invalid_private_interfaces_refuse_without_render"),
            ("sanitizer fixed name blocks scale", overlay,
             '    container_name: "${COMPOSE_PROJECT_NAME}-sanitizer-servicenow-control"\n', "",
             "test_core_zero_traceback_and_single_owner_replacement_render"),
            ("sanitizer one owner validation", script,
             'if (service.get("scale") != 1 or service.get("deploy", {}).get("replicas") != 1 or',
             'if (False and (service.get("scale") != 1 or service.get("deploy", {}).get("replicas") != 1) or',
             "test_renderer_refuses_missing_sanitizer_single_owner_guards"),
        ]
        for label, filename, old, new, method in mutations:
            source = (ROOT / filename).read_text()
            self.assertIn(old, source, label)
            with self.subTest(guard=label), tempfile.TemporaryDirectory(prefix="k1-compose-mutant-", dir=SCRATCH) as name:
                root = Path(name)
                for file in (overlay, script, "scripts/bootstrap-servicenow-control.py",
                             "docker-compose.customer.yml", "docker-compose.self-hosted.yml",
                             "docker-compose.self-hosted-byok.yml"):
                    target = root / file
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes((ROOT / file).read_bytes())
                (root / filename).write_text(source.replace(old, new, 1))
                result = subprocess.run(["python3", str(ROOT / "tests/test_servicenow_control_compose.py"),
                                         "ComposeTests." + method], capture_output=True, timeout=45,
                                        env=dict(os.environ, K1_COMPOSE_ROOT=name, PYTHONDONTWRITEBYTECODE="1"))
                self.assertEqual(1, result.returncode, label)
                self.assertIn(("FAIL: " + method).encode(), result.stderr, label)
                print(label + " mutant: RED")

    def test_bootstrap_protective_mutants_turn_red(self):
        source = (ROOT / "scripts/bootstrap-servicenow-control.py").read_text()
        suite = ROOT / "tests/test_servicenow_control_bootstrap.py"
        mutations = [
            ("0600 custody", "stat.S_IMODE(info.st_mode) != mode", "False",
             "test_loose_permissions_refused_without_repair"),
            ("hardlink custody", "(not directory and info.st_nlink != 1)", "False",
             "test_hardlink_refused"),
            ("workload owner", "info.st_uid != uid", "False",
             "test_workload_owner_mismatch_refused"),
            ("extended ACL", ('if {"system.posix_acl_access", "system.posix_acl_default"} & set(os.listxattr(path)):'
                              if sys.platform.startswith("linux") else
                              'if result.returncode or len(result.stdout.splitlines()) != 1:'),
             "if False:", "test_extended_acl_refused"),
            ("single PEM", 'if not re.fullmatch(pattern, path.read_bytes()):',
             "if False:", "test_appended_ca_refused"),
            ("key pair", 'if public != openssl("pkey", "-in", key, "-pubout"):', "if False:",
             "test_wrong_key_refused"),
            ("exact SAN", 'if len(san) != 2 or san[1].strip() != "DNS:" + identity:', "if False:",
             "test_rerun_rejects_extra_san"),
            ("leaf CA false", 'if len(constraints) != 2 or constraints[1].strip() != "CA:FALSE":',
             "if False:", "test_rerun_rejects_ca_true_leaf"),
            ("exact EKU", 'if len(eku) != 2 or set(eku[1].strip().split(", ")) != {\n'
             '                "TLS Web Server Authentication", "TLS Web Client Authentication"}:',
             "if False:", "test_rerun_rejects_extra_eku"),
            ("bootstrap lock", "fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass",
             "test_bootstrap_lock_refused"),
            ("CA signature", 'openssl("verify", "-CAfile", ca, "-purpose", purpose,\n'
             '                    "-verify_hostname", identity, cert)', "pass",
             "test_rerun_rejects_foreign_ca_leaf"),
        ]
        expiry = source.replace('"-verify_hostname", identity, cert)',
                                '"-no_check_time", "-verify_hostname", identity, cert)')
        expiry = expiry.replace('openssl("x509", "-in", cert, "-noout", "-checkend", "86400")', "pass")
        variants = []
        for label, old, new, method in mutations:
            self.assertEqual(1, source.count(old), label)
            variants.append((label, source.replace(old, new), method))
        self.assertNotEqual(source, expiry)
        variants.append(("expiry", expiry, "test_rerun_rejects_expired_leaf"))
        for label, mutant, method in variants:
            with self.subTest(guard=label), tempfile.TemporaryDirectory(prefix="k1-mutant-", dir=SCRATCH) as name:
                root = Path(name)
                (root / "scripts").mkdir()
                (root / "scripts/bootstrap-servicenow-control.py").write_text(mutant)
                env = dict(os.environ, K1_TEST_ROOT=name, PYTHONDONTWRITEBYTECODE="1")
                result = subprocess.run(["python3", str(suite), "BootstrapTests." + method],
                                        env=env, capture_output=True, timeout=30)
                self.assertEqual(1, result.returncode, label)
                self.assertIn(("FAIL: " + method).encode(), result.stderr, label)
                print(label + " mutant: RED")

    def test_off_render_mutant_turns_red(self):
        with tempfile.TemporaryDirectory(prefix="k1-render-mutant-", dir=SCRATCH) as name:
            root = Path(name)
            for file in ("docker-compose.customer.yml", "docker-compose.self-hosted.yml",
                         "docker-compose.self-hosted-byok.yml"):
                shutil.copyfile(ROOT / file, root / file)
            compose = root / "docker-compose.customer.yml"
            source = compose.read_text()
            old = 'SANITIZER_URL: "http://sanitizer:8086"'
            self.assertEqual(1, source.count(old))
            compose.write_text(source.replace(old, 'SANITIZER_URL: "https://sanitizer:8086"'))
            env = dict(os.environ, K1_OFF_RENDER_ROOT=name, PYTHONDONTWRITEBYTECODE="1")
            result = subprocess.run(["python3", str(ROOT / "tests/test_servicenow_control_off.py"),
                                     "OffRenderTests.test_off_render_bytes_equal_main"],
                                    env=env, capture_output=True, timeout=30)
            self.assertEqual(1, result.returncode)
            self.assertIn(b"FAIL: test_off_render_bytes_equal_main", result.stderr)
            print("OFF render mutant: RED")


if __name__ == "__main__":
    unittest.main()
