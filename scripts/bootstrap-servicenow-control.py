#!/usr/bin/env python3
"""Issue deploy-local control TLS credentials; does not enable a listener.

Run as the operator with authority to chown leaf material to the image UID:
  python3 scripts/bootstrap-servicenow-control.py /path/to/control-certs
Mount only material/gateway or material/sanitizer read-only into that workload.
Each contains ca.crt, tls.crt and tls.key. Never mount material/operator.
The default workload UID/GID is 10001; verify image and bind-mount ownership before use.
"""

import argparse
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


class Invalid(Exception):
    pass


def openssl(*args, data=None):
    result = subprocess.run(["openssl", *map(str, args)], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    if result.returncode:
        raise Invalid("certificate operation failed")
    return result.stdout


def custody(path, mode, uid, gid, directory=False):
    info = path.lstat()
    kind_ok = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)
    if (not kind_ok or stat.S_IMODE(info.st_mode) != mode or info.st_uid != uid
            or info.st_gid != gid or (not directory and info.st_nlink != 1)):
        raise Invalid("unsafe certificate custody")
    if sys.platform == "darwin":
        # POSIX modes do not mask macOS extended ACL grants.
        result = subprocess.run(["/bin/ls", "-lde", str(path)], capture_output=True,
                                env={"LC_ALL": "C"}, timeout=5)
        if result.returncode or len(result.stdout.splitlines()) != 1:
            raise Invalid("extended ACL custody")
    elif sys.platform.startswith("linux"):
        if {"system.posix_acl_access", "system.posix_acl_default"} & set(os.listxattr(path)):
            raise Invalid("extended ACL custody")
    else:
        raise Invalid("unsupported custody platform")


def single_pem(path, kind):
    marker = kind.encode("ascii")
    pattern = (rb"-----BEGIN " + marker + rb"-----\r?\n"
               rb"[A-Za-z0-9+/=\r\n]+-----END " + marker + rb"-----\r?\n?")
    if not re.fullmatch(pattern, path.read_bytes()):
        raise Invalid("ambiguous certificate material")


def key_matches(cert, key):
    public = openssl("x509", "-in", cert, "-pubkey", "-noout")
    if public != openssl("pkey", "-in", key, "-pubout"):
        raise Invalid("certificate key mismatch")


def validate(material, uid, gid):
    operator = material / "operator"
    custody(material, 0o700, os.geteuid(), os.getegid(), True)
    custody(operator, 0o700, os.geteuid(), os.getegid(), True)
    if set(p.name for p in material.iterdir()) != {"operator", *IDENTITIES}:
        raise Invalid("unexpected certificate material")
    if set(p.name for p in operator.iterdir()) != {"ca.crt", "ca.key"}:
        raise Invalid("unexpected operator material")
    for name in ("ca.crt", "ca.key"):
        custody(operator / name, 0o600, os.geteuid(), os.getegid())
        single_pem(operator / name, "CERTIFICATE" if name.endswith(".crt") else "PRIVATE KEY")
    ca = operator / "ca.crt"
    key_matches(ca, operator / "ca.key")
    openssl("verify", "-check_ss_sig", "-CAfile", ca, ca)
    constraints = openssl("x509", "-in", ca, "-noout", "-ext", "basicConstraints").decode()
    if "CA:TRUE" not in constraints:
        raise Invalid("invalid CA constraints")
    for role, identity in IDENTITIES.items():
        leaf = material / role
        custody(leaf, 0o700, uid, gid, True)
        if set(p.name for p in leaf.iterdir()) != {"ca.crt", "tls.crt", "tls.key"}:
            raise Invalid("unexpected workload material")
        for name in ("ca.crt", "tls.crt", "tls.key"):
            custody(leaf / name, 0o600, uid, gid)
            single_pem(leaf / name, "CERTIFICATE" if name.endswith(".crt") else "PRIVATE KEY")
        if (leaf / "ca.crt").read_bytes() != ca.read_bytes():
            raise Invalid("CA mismatch")
        cert = leaf / "tls.crt"
        key_matches(cert, leaf / "tls.key")
        san = openssl("x509", "-in", cert, "-noout", "-ext", "subjectAltName").decode().splitlines()
        eku = openssl("x509", "-in", cert, "-noout", "-ext", "extendedKeyUsage").decode().splitlines()
        if len(san) != 2 or san[1].strip() != "DNS:" + identity:
            raise Invalid("unexpected peer SAN")
        if len(eku) != 2 or set(eku[1].strip().split(", ")) != {
                "TLS Web Server Authentication", "TLS Web Client Authentication"}:
            raise Invalid("unexpected peer EKU")
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
        raise Invalid("invalid workload owner")
    if os.geteuid() != 0 and (uid, gid) != (os.geteuid(), os.getegid()):
        raise Invalid("operator must be able to assign workload ownership")
    root = root.absolute()
    for path in (root, *root.parents):
        if path.is_symlink():
            raise Invalid("symlink certificate path")
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
            raise Invalid("bootstrap already running") from None
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--workload-uid", type=int, default=10001)
    parser.add_argument("--workload-gid", type=int, default=10001)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        bootstrap(args.directory, args.workload_uid, args.workload_gid)
    except (Invalid, OSError, subprocess.SubprocessError):
        print("control certificate bootstrap refused", file=sys.stderr)
        return 1
    print("control certificates verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
