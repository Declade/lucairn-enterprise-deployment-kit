#!/usr/bin/env python3
"""Issue deploy-local control TLS credentials; does not enable a listener.

Run as the operator with authority to chown leaf material to the image UID:
  python3 scripts/bootstrap-servicenow-control.py /path/to/control-certs
Mount only material/gateway or material/sanitizer read-only into that workload.
Each contains ca.crt, tls.crt and tls.key. Never mount material/operator.
The default workload UID/GID is 10001; verify image and bind-mount ownership before use.
"""

import argparse
import errno
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


IDENTITIES = {"gateway": "gateway.servicenow-control", "sanitizer": "sanitizer.servicenow-control"}


REASONS = frozenset({"args", "custody", "acl_check_unavailable", "certificate", "validation"})


class Invalid(Exception):
    def __init__(self, reason="validation"):
        self.reason = reason if reason in REASONS else "validation"
        super().__init__(self.reason)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default diagnostics echo the rejected argument's value.
        self.exit(2, "control certificate bootstrap refused: args\n")


def check_acl(path):
    if sys.platform == "darwin":
        # POSIX modes do not mask macOS extended ACL grants.
        try:
            result = subprocess.run(["/bin/ls", "-lde", str(path)], capture_output=True,
                                    env={"LC_ALL": "C"}, timeout=5)
        except (OSError, subprocess.SubprocessError):
            raise Invalid("acl_check_unavailable") from None
        if result.returncode:
            raise Invalid("acl_check_unavailable")
        if len(result.stdout.splitlines()) != 1:
            raise Invalid("custody")
    elif sys.platform.startswith("linux"):
        # No external ACL utility is required on Linux. Unsupported xattrs or
        # absent attributes mean no ACL; permission/I/O errors fail closed.
        absent = {errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENODATA,
                  getattr(errno, "ENOATTR", errno.ENODATA)}
        try:
            names = set(os.listxattr(path, follow_symlinks=False))
            for name in ("system.posix_acl_access", "system.posix_acl_default"):
                try:
                    os.getxattr(path, name, follow_symlinks=False)
                except OSError as error:
                    if error.errno not in absent:
                        raise
                    if name not in names:
                        continue
                raise Invalid("custody")
        except OSError as error:
            if error.errno not in absent:
                raise Invalid("acl_check_unavailable") from None
        except AttributeError:
            raise Invalid("acl_check_unavailable") from None
    else:
        raise Invalid("acl_check_unavailable")


def openssl(*args, data=None):
    try:
        result = subprocess.run(["openssl", *map(str, args)], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    except (OSError, subprocess.SubprocessError):
        raise Invalid("certificate") from None
    if result.returncode:
        raise Invalid("certificate")
    return result.stdout


def custody(path, mode, uid, gid, directory=False):
    info = path.lstat()
    kind_ok = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if (not kind_ok or stat.S_IMODE(info.st_mode) != mode or info.st_uid != uid
            or info.st_gid != gid or (not directory and info.st_nlink != 1)):
        raise Invalid("custody")
    check_acl(path)


def single_pem(path, kind):
    marker = kind.encode("ascii")
    pattern = (rb"-----BEGIN " + marker + rb"-----\r?\n"
               rb"[A-Za-z0-9+/=\r\n]+-----END " + marker + rb"-----\r?\n?")
    if not re.fullmatch(pattern, path.read_bytes()):
        raise Invalid("certificate")


def key_matches(cert, key):
    public = openssl("x509", "-in", cert, "-pubkey", "-noout")
    if public != openssl("pkey", "-in", key, "-pubout"):
        raise Invalid("certificate")


def validate(material, uid, gid):
    operator = material / "operator"
    custody(material, 0o700, os.geteuid(), os.getegid(), True)
    custody(operator, 0o700, os.geteuid(), os.getegid(), True)
    if set(p.name for p in material.iterdir()) != {"operator", *IDENTITIES}:
        raise Invalid("certificate")
    if set(p.name for p in operator.iterdir()) != {"ca.crt", "ca.key"}:
        raise Invalid("certificate")
    for name in ("ca.crt", "ca.key"):
        custody(operator / name, 0o600, os.geteuid(), os.getegid())
        single_pem(operator / name, "CERTIFICATE" if name.endswith(".crt") else "PRIVATE KEY")
    ca = operator / "ca.crt"
    key_matches(ca, operator / "ca.key")
    openssl("verify", "-check_ss_sig", "-CAfile", ca, ca)
    constraints = openssl("x509", "-in", ca, "-noout", "-ext", "basicConstraints").decode()
    if "CA:TRUE" not in constraints:
        raise Invalid("certificate")
    for role, identity in IDENTITIES.items():
        leaf = material / role
        custody(leaf, 0o700, uid, gid, True)
        if set(p.name for p in leaf.iterdir()) != {"ca.crt", "tls.crt", "tls.key"}:
            raise Invalid("certificate")
        for name in ("ca.crt", "tls.crt", "tls.key"):
            custody(leaf / name, 0o600, uid, gid)
            single_pem(leaf / name, "CERTIFICATE" if name.endswith(".crt") else "PRIVATE KEY")
        if (leaf / "ca.crt").read_bytes() != ca.read_bytes():
            raise Invalid("certificate")
        cert = leaf / "tls.crt"
        key_matches(cert, leaf / "tls.key")
        constraints = openssl("x509", "-in", cert, "-noout", "-ext", "basicConstraints").decode().splitlines()
        if len(constraints) != 2 or constraints[1].strip() != "CA:FALSE":
            raise Invalid("certificate")
        san = openssl("x509", "-in", cert, "-noout", "-ext", "subjectAltName").decode().splitlines()
        eku = openssl("x509", "-in", cert, "-noout", "-ext", "extendedKeyUsage").decode().splitlines()
        if len(san) != 2 or san[1].strip() != "DNS:" + identity:
            raise Invalid("certificate")
        if len(eku) != 2 or set(eku[1].strip().split(", ")) != {
                "TLS Web Server Authentication", "TLS Web Client Authentication"}:
            raise Invalid("certificate")
        for purpose in ("sslserver", "sslclient"):
            openssl("verify", "-CAfile", ca, "-purpose", purpose,
                    "-verify_hostname", identity, cert)
        openssl("x509", "-in", cert, "-noout", "-checkend", "86400")


def generate(stage, uid, gid):
    operator = stage / "operator"
    operator.mkdir(mode=0o700)
    ca, ca_key = operator / "ca.crt", operator / "ca.key"
    openssl("genpkey", "-algorithm", "ED25519", "-out", ca_key)
    openssl("req", "-new", "-x509", "-days", "3650", "-key", ca_key,
            "-out", ca, "-subj", "/CN=lucairn-servicenow-control-ca",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "subjectKeyIdentifier=hash",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign")
    for role, identity in IDENTITIES.items():
        leaf = stage / role
        leaf.mkdir(mode=0o700)
        key, cert = leaf / "tls.key", leaf / "tls.crt"
        openssl("genpkey", "-algorithm", "ED25519", "-out", key)
        request = openssl("req", "-new", "-key", key, "-subj", "/CN=" + role)
        extensions = stage / "leaf.ext"
        extensions.write_text("basicConstraints=critical,CA:FALSE\n"
                              "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n"
                              "keyUsage=critical,digitalSignature\n"
                              "extendedKeyUsage=serverAuth,clientAuth\n"
                              "subjectAltName=DNS:" + identity + "\n")
        openssl("x509", "-req", "-CA", ca, "-CAkey", ca_key,
                "-set_serial", "0x" + os.urandom(16).hex(), "-days", "365",
                "-out", cert, "-extfile", extensions, data=request)
        extensions.unlink()
        shutil.copyfile(ca, leaf / "ca.crt")
        for path in leaf.iterdir():
            path.chmod(0o600)
            os.chown(path, uid, gid)
        os.chown(leaf, uid, gid)
    for path in operator.iterdir():
        path.chmod(0o600)


def bootstrap(root, uid, gid):
    if uid < 0 or gid < 0:
        raise Invalid("args")
    if os.geteuid() != 0 and (uid, gid) != (os.geteuid(), os.getegid()):
        raise Invalid("custody")
    root = root.absolute()
    for path in (root, *root.parents):
        if path.is_symlink():
            raise Invalid("custody")
    # Parent directory is chosen/created by the operator, never permission-repaired.
    if not root.exists():
        root.mkdir(mode=0o700)
        os.chown(root, os.geteuid(), os.getegid())
    custody(root, 0o700, os.geteuid(), os.getegid(), True)
    lock_path = root / ".bootstrap.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        custody(lock_path, 0o600, os.geteuid(), os.getegid())
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Invalid("custody") from None
        material = root / "material"
        if material.exists() or material.is_symlink():
            validate(material, uid, gid)
            return
        stage = Path(tempfile.mkdtemp(prefix=".staging-", dir=root))
        try:
            generate(stage, uid, gid)
            validate(stage, uid, gid)
            stage.rename(material)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    finally:
        os.close(fd)


def main():
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--workload-uid", type=int, default=10001)
    parser.add_argument("--workload-gid", type=int, default=10001)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        bootstrap(args.directory, args.workload_uid, args.workload_gid)
    except Exception as error:
        reason = error.reason if isinstance(error, Invalid) else (
            "custody" if isinstance(error, OSError) else "validation")
        print("control certificate bootstrap refused: " + reason, file=sys.stderr)
        return 1
    print("control certificates verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
