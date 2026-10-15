"""Synthetic credential tests. These do not test DSA control listeners."""

import concurrent.futures
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest


SCRATCH = str(Path(tempfile.gettempdir()).resolve())

ROOT = Path(os.environ.get("K1_TEST_ROOT", Path(__file__).resolve().parents[1]))
SCRIPT = ROOT / "scripts/bootstrap-servicenow-control.py"
spec = importlib.util.spec_from_file_location("bootstrap", SCRIPT)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def run(*args):
    return subprocess.run(list(map(str, args)), capture_output=True, timeout=20)


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="k1-certs-", dir=SCRATCH)
        cls.base = Path(cls.scratch.name) / "base"
        result = cls.invoke(cls.base)
        if result.returncode:
            raise AssertionError("fresh bootstrap failed: " + result.stderr.decode())

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    @staticmethod
    def invoke(path):
        return run("python3", SCRIPT, path, "--workload-uid", os.getuid(),
                   "--workload-gid", os.getgid())

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="k1-case-", dir=SCRATCH)
        self.root = Path(self.temp.name) / "certs"
        shutil.copytree(self.base, self.root)
        for path in (self.root, *self.root.rglob("*")):
            os.chown(path, os.getuid(), os.getgid())
        self.material = self.root / "material"

    def tearDown(self):
        self.temp.cleanup()

    def test_fresh_san_eku_and_custody(self):
        # Oracle: design v3 §4.2, explicit SAN + BOTH EKUs, not CN or CA alone.
        for role, identity in (("gateway", "gateway.servicenow-control"),
                               ("sanitizer", "sanitizer.servicenow-control")):
            leaf = self.material / role
            self.assertEqual(0o700, leaf.stat().st_mode & 0o777)
            self.assertEqual({"ca.crt", "tls.crt", "tls.key"}, {p.name for p in leaf.iterdir()})
            for path in leaf.iterdir():
                self.assertEqual(0o600, path.stat().st_mode & 0o777)
                self.assertEqual(os.getuid(), path.stat().st_uid)
            san = run("openssl", "x509", "-in", leaf / "tls.crt", "-noout", "-ext", "subjectAltName")
            self.assertEqual("DNS:" + identity, san.stdout.decode().splitlines()[1].strip())
            for purpose in ("sslserver", "sslclient"):
                self.assertEqual(0, self.verify(role, identity, purpose).returncode)
        self.assertEqual(0o700, (self.material / "operator").stat().st_mode & 0o777)
        self.assertEqual(0o600, (self.material / "operator/ca.key").stat().st_mode & 0o777)

    def digest(self):
        return {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).digest()
                for p in self.root.rglob("*") if p.is_file()}

    def test_rerun_preserves_every_material_byte(self):
        before = self.digest()
        self.assertEqual(0, self.invoke(self.root).returncode)
        self.assertEqual(before, self.digest())

    def test_loose_permissions_refused_without_repair(self):
        path = self.material / "gateway/tls.key"
        path.chmod(0o644)
        self.assertNotEqual(0, self.invoke(self.root).returncode)
        self.assertEqual(0o644, path.stat().st_mode & 0o777)

    def test_symlink_refused(self):
        path = self.material / "gateway/tls.key"
        path.rename(path.with_name("saved.key"))
        path.symlink_to("saved.key")
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_hardlink_refused(self):
        os.link(self.material / "gateway/tls.key", Path(self.temp.name) / "alias")
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_workload_owner_mismatch_refused(self):
        with self.assertRaises(bootstrap.Invalid):
            bootstrap.custody(self.material / "gateway/tls.key", 0o600,
                              os.getuid() + 1, os.getgid())

    def test_extended_acl_refused(self):
        path = self.material / "gateway/tls.key"
        if sys.platform == "darwin":
            result = run("/bin/chmod", "+a", "user:nobody allow read", path)
            self.assertEqual(0, result.returncode)
            try:
                self.assertEqual(0o600, path.stat().st_mode & 0o777)
                self.assertNotEqual(0, self.invoke(self.root).returncode)
            finally:
                run("/bin/chmod", "-N", path)
        elif sys.platform.startswith("linux"):
            import struct
            # Linux POSIX ACL xattr v2: a named reader masked to zero keeps the
            # POSIX mode 0600, so this exercises ACL rejection independently.
            entries = ((1, 6, 0xffffffff), (2, 4, 65534), (4, 0, 0xffffffff),
                       (16, 0, 0xffffffff), (32, 0, 0xffffffff))
            acl = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", *entry) for entry in entries)
            os.setxattr(path, "system.posix_acl_access", acl)
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
            self.assertNotEqual(0, self.invoke(self.root).returncode)
        else:
            self.fail("custody platform is unsupported")

    def test_appended_ca_refused(self):
        foreign = Path(self.temp.name) / "foreign"
        self.assertEqual(0, self.invoke(foreign).returncode)
        ca = self.material / "operator/ca.crt"
        ca.write_bytes(ca.read_bytes() + (foreign / "material/operator/ca.crt").read_bytes())
        for role in ("gateway", "sanitizer"):
            shutil.copyfile(ca, self.material / role / "ca.crt")
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_appended_private_material_refused(self):
        cert = self.material / "gateway/tls.crt"
        cert.write_bytes(cert.read_bytes() + (self.material / "operator/ca.key").read_bytes())
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_partial_material_refused_without_rotation(self):
        before = (self.material / "operator/ca.key").read_bytes()
        (self.material / "sanitizer/tls.crt").unlink()
        self.assertNotEqual(0, self.invoke(self.root).returncode)
        self.assertEqual(before, (self.material / "operator/ca.key").read_bytes())

    def test_wrong_key_refused(self):
        shutil.copyfile(self.material / "sanitizer/tls.key", self.material / "gateway/tls.key")
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_bootstrap_lock_refused(self):
        import fcntl
        with (self.root / ".bootstrap.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(0, self.invoke(self.root).returncode)

    def verify(self, role, identity, purpose="sslserver", *extra):
        return run("openssl", "verify", "-CAfile", self.material / "operator/ca.crt",
                   "-purpose", purpose, "-verify_hostname", identity,
                   *extra, self.material / role / "tls.crt")

    def test_wrong_peer_and_server_name_rejected_by_openssl(self):
        self.assertNotEqual(0, self.verify("gateway", "sanitizer.servicenow-control").returncode)
        self.assertNotEqual(0, self.verify("sanitizer", "gateway.servicenow-control").returncode)
        self.assertNotEqual(0, self.verify("gateway", "wrong.invalid").returncode)

    def test_expired_rejected_by_openssl(self):
        result = self.verify("gateway", "gateway.servicenow-control", "sslserver",
                             "-attime", str(int(time.time()) + 400 * 86400))
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b"expired", result.stderr)

    def replace_leaf(self, role, san, eku, expired=False, constraints="CA:FALSE"):
        leaf = self.material / role
        request = run("openssl", "req", "-new", "-key", leaf / "tls.key", "-subj", "/CN=synthetic")
        self.assertEqual(0, request.returncode)
        ext = Path(self.temp.name) / "test.ext"
        ext.write_text((f"basicConstraints=critical,{constraints}\n" if constraints else "") +
                       "keyUsage=digitalSignature\n"
                       "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n"
                       f"subjectAltName=DNS:{san}\nextendedKeyUsage={eku}\n")
        command = ["openssl", "x509", "-req", "-CA",
                                 str(self.material / "operator/ca.crt"), "-CAkey",
                                 str(self.material / "operator/ca.key"), "-set_serial", "42",
                                 "-days", "365", "-out", str(leaf / "tls.crt"),
                                 "-extfile", str(ext)]
        if expired:
            (leaf / "tls.crt").unlink()
            scratch = Path(self.temp.name)
            (scratch / "index").touch()
            (scratch / "serial").write_text("42\n")
            config = scratch / "ca.cnf"
            (scratch / "request.pem").write_bytes(request.stdout)
            config.write_text(f"[ca]\ndefault_ca=issuer\n[issuer]\n"
                              f"database={scratch}/index\nserial={scratch}/serial\n"
                              f"new_certs_dir={scratch}\n"
                              f"certificate={self.material}/operator/ca.crt\n"
                              f"private_key={self.material}/operator/ca.key\n"
                              "default_md=default\npolicy=policy\n[policy]\ncommonName=supplied\n"
                              "[leaf]\n" + ext.read_text())
            command = ["openssl", "ca", "-batch", "-notext", "-config", str(config),
                       "-in", str(scratch / "request.pem"),
                       "-extensions", "leaf", "-startdate", "20200101000000Z",
                       "-enddate", "20200102000000Z", "-out", str(leaf / "tls.crt")]
        signed = subprocess.run(command, input=request.stdout,
                                capture_output=True, timeout=15)
        self.assertEqual(0, signed.returncode)
        (leaf / "tls.crt").chmod(0o600)

    def test_rerun_rejects_wrong_san(self):
        self.replace_leaf("gateway", "other.servicenow-control", "serverAuth,clientAuth")
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_rerun_rejects_extra_san(self):
        self.replace_leaf("gateway", "gateway.servicenow-control,DNS:other.invalid", "serverAuth,clientAuth")
        self.assertEqual(0, self.verify("gateway", "gateway.servicenow-control").returncode)
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_rerun_rejects_extra_eku(self):
        self.replace_leaf("gateway", "gateway.servicenow-control", "serverAuth,clientAuth,codeSigning")
        self.assertEqual(0, self.verify("gateway", "gateway.servicenow-control").returncode)
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_rerun_rejects_ca_true_leaf(self):
        for role in ("gateway", "sanitizer"):
            with self.subTest(role=role):
                identity = role + ".servicenow-control"
                self.replace_leaf(role, identity, "serverAuth,clientAuth", constraints="CA:TRUE")
                # Otherwise valid TLS leaves must fail specifically on CA:TRUE.
                for purpose in ("sslserver", "sslclient"):
                    self.assertEqual(0, self.verify(role, identity, purpose).returncode)
                self.assertNotEqual(0, self.invoke(self.root).returncode)
                self.replace_leaf(role, identity, "serverAuth,clientAuth")

    def test_rerun_rejects_missing_leaf_constraints(self):
        self.replace_leaf("gateway", "gateway.servicenow-control", "serverAuth,clientAuth", constraints=None)
        self.assertEqual(0, self.verify("gateway", "gateway.servicenow-control").returncode)
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_rerun_rejects_expired_leaf(self):
        self.replace_leaf("gateway", "gateway.servicenow-control", "serverAuth,clientAuth", expired=True)
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_rerun_rejects_foreign_ca_leaf(self):
        foreign = Path(self.temp.name) / "foreign"
        self.assertEqual(0, self.invoke(foreign).returncode)
        for name in ("tls.crt", "tls.key"):
            shutil.copyfile(foreign / "material/gateway" / name, self.material / "gateway" / name)
        self.assertNotEqual(0, self.invoke(self.root).returncode)

    def test_rerun_and_openssl_reject_wrong_eku(self):
        self.replace_leaf("gateway", "gateway.servicenow-control", "clientAuth")
        self.assertNotEqual(0, self.invoke(self.root).returncode)
        self.assertNotEqual(0, self.verify("gateway", "gateway.servicenow-control").returncode)

    def handshake(self, client_role):
        # A test-local TLS peer, not a production listener. socketpair avoids binding ports.
        server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.load_cert_chain(self.material / "gateway/tls.crt", self.material / "gateway/tls.key")
        server.load_verify_locations(self.material / "operator/ca.crt")
        server.verify_mode = ssl.CERT_REQUIRED
        client = ssl.create_default_context(cafile=self.material / "operator/ca.crt")
        if client_role:
            client.load_cert_chain(self.material / client_role / "tls.crt",
                                   self.material / client_role / "tls.key")
        left, right = socket.socketpair()
        left.settimeout(3)
        right.settimeout(3)

        def accept():
            try:
                with server.wrap_socket(left, server_side=True) as tls:
                    if tls.getpeercert().get("subjectAltName") != (("DNS", "sanitizer.servicenow-control"),):
                        return False
                    tls.sendall(b"ok")
                    return True
            except (ssl.SSLError, OSError):
                return False

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(accept)
            try:
                with client.wrap_socket(right, server_hostname="gateway.servicenow-control") as tls:
                    received = tls.recv(2)
            except (ssl.SSLError, OSError):
                received = b""
            return future.result(timeout=5), received

    def test_synthetic_mtls_accepts_expected_peer_and_rejects_no_cert(self):
        self.assertEqual((True, b"ok"), self.handshake("sanitizer"))
        self.assertEqual((False, b""), self.handshake(None))

    def test_synthetic_exact_peer_rejects_other_valid_ca_member(self):
        self.assertEqual((False, b""), self.handshake("gateway"))

    def test_synthetic_tls_peer_rejects_plaintext(self):
        server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server.load_cert_chain(self.material / "gateway/tls.crt", self.material / "gateway/tls.key")
        left, right = socket.socketpair()
        left.settimeout(3)
        right.settimeout(3)
        with right:
            right.sendall(b"GET /internal/v1/servicenow/snapshot HTTP/1.0\r\n\r\n")
            with self.assertRaises(ssl.SSLError):
                server.wrap_socket(left, server_side=True)
        left.close()


if __name__ == "__main__":
    unittest.main()
