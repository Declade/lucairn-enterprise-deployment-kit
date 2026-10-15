#!/usr/bin/env python3
"""K2 synthetic Helm acceptance. No cluster, network, install or release action.

Production ON rendering is held. Only temporary chart copies remove the hold.
Run: python3 -m unittest discover -s tests -p test_servicenow_control_helm.py -v
"""
import copy
import importlib.machinery
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/lucairn"
APP = "app.kubernetes.io/name"
HELD = "templates/servicenow-control-held.yaml"
ON = {"global": {"servicenowControl": {
    "enabled": True, "gatewaySecret": "synthetic-gateway-control",
    "sanitizerSecret": "synthetic-sanitizer-control",
    "instanceCIDRs": ["198.51.100.0/24", "10.250.0.0/24"],
    "instanceDNSNames": ["instance.synthetic.test"],
    "kubernetesAPICIDRs": ["10.96.0.1/32", "192.0.2.1/32"],
    "clusterCIDRs": ["10.244.0.0/16", "10.96.0.0/12"],
}}}
SECRET_ARGS = ["--set", "global.skipPullSecretGuard=true"]
for key in ["admin.adminPassword", "audit.postgresPassword", "audit.auditAppPassword",
            "id-bridge.postgresPassword", "observability.grafanaAdminPassword",
            "sandbox-a.postgresPassword", "veil-witness.postgresPassword",
            "veil-witness.veilAppPassword"]:
    chart, name = key.split(".")
    SECRET_ARGS += ["--set-string", f"{chart}.secrets.values.{name}=kit-harness-not-a-real-secret"]
SECRET_ARGS += ["--set-string", "veil-witness.secrets.values.signingKey=" + "1" * 64]


def merge(a, b):
    result = copy.deepcopy(a)
    for k, v in b.items():
        result[k] = merge(result.get(k, {}), v) if isinstance(v, dict) else copy.deepcopy(v)
    return result


def render(chart, config=None, profile="values-test.yaml"):
    with tempfile.TemporaryDirectory(prefix="k2-values-") as tmp:
        values = Path(tmp) / "values.yaml"
        values.write_text(yaml.safe_dump(config or {}))
        args = ["helm", "template", "k2", str(chart), "-f", str(chart / profile),
                "-f", str(values), *SECRET_ARGS]
        return subprocess.run(args, capture_output=True, text=True, timeout=30)


def docs(output):
    return [d for d in yaml.safe_load_all(output) if d]


def obj(items, kind, name):
    matches = [d for d in items if d.get("kind") == kind and d["metadata"]["name"] == name]
    if len(matches) != 1:
        raise AssertionError(f"expected exactly one {kind} named {name}, found {len(matches)}")
    return matches[0]


def select(selector, labels):
    for k, v in selector.get("matchLabels", {}).items():
        if labels.get(k) != v:
            return False
    for e in selector.get("matchExpressions", []):
        k, op, vals = e["key"], e["operator"], e.get("values", [])
        if op == "In" and labels.get(k) not in vals:
            return False
        if op == "NotIn" and labels.get(k) in vals:
            return False
        if op == "Exists" and k not in labels:
            return False
        if op == "DoesNotExist" and k in labels:
            return False
    return True


class Union:
    """Evaluate rendered Kubernetes policy directions independently, then AND.

    External addresses have no namespace or pod identity. Unisolated directions
    allow traffic. Empty peer/port lists allow all, as do omitted lists.
    Cilium DNS policies in these renders add only DNS traffic, outside 443/control.
    """
    def __init__(self, items):
        self.policies = [d for d in items if d.get("kind") == "NetworkPolicy"]
        self.namespaces = {d["metadata"]["name"]: dict(d["metadata"].get("labels", {}),
            **{"kubernetes.io/metadata.name": d["metadata"]["name"]})
            for d in items if d.get("kind") == "Namespace"}

    def peer(self, p, other, policy_ns):
        if "ipBlock" in p:
            if "ip" not in other:
                return False
            address = ipaddress.ip_address(other["ip"])
            block = p["ipBlock"]
            return address in ipaddress.ip_network(block["cidr"]) and not any(
                address in ipaddress.ip_network(c) for c in block.get("except", []))
        if not p:
            return True
        if other.get("ns") is None:
            return False
        if "namespaceSelector" in p:
            if not select(p["namespaceSelector"], self.namespaces.get(other["ns"], {})):
                return False
        elif other["ns"] != policy_ns:
            return False
        return "podSelector" not in p or select(p["podSelector"], other["labels"])

    @staticmethod
    def port(rule, number, target, protocol):
        for p in rule.get("ports") or [{}]:
            if p.get("protocol", "TCP") != protocol:
                continue
            start = p.get("port")
            if start is None:
                return True
            if isinstance(start, str):
                start = target.get("ports", {}).get(start)
            if start is not None and start <= number <= p.get("endPort", start):
                return True
        return False

    def allows(self, owner, other, direction, port, protocol="TCP"):
        policies = [p for p in self.policies if p["metadata"]["namespace"] == owner["ns"]
            and select(p["spec"]["podSelector"], owner["labels"])
            and direction in p["spec"].get("policyTypes", ["Ingress"] +
                (["Egress"] if "egress" in p["spec"] else []))]
        if not policies:
            return True
        key, peers = ("ingress", "from") if direction == "Ingress" else ("egress", "to")
        target = owner if direction == "Ingress" else other
        return any(self.port(r, port, target, protocol) and any(
            self.peer(p, other, policy["metadata"]["namespace"])
            for p in r.get(peers) or [{}])
            for policy in policies for r in policy["spec"].get(key, []))

    def reaches(self, source, dest, port):
        return self.allows(source, dest, "Egress", port) and self.allows(dest, source, "Ingress", port)


def pod(name, namespace, **labels):
    return {"ns": namespace, "labels": {APP: name, "app.kubernetes.io/part-of": "dsa", **labels},
            "ports": {"sn-control": 18443 if name == "gateway" else 18444}}


GATEWAY = pod("gateway", "dsa-edge")
SANITIZER = pod("sandbox-a", "dsa-identity")


class HelmAcceptance(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("helm"):
            raise RuntimeError("helm is missing; do not install it for this task")
        cls.tmp = tempfile.TemporaryDirectory(prefix="k2-acceptance-")
        cls.work = Path(cls.tmp.name)
        cls.chart = cls.work / "assembled"
        shutil.copytree(CHART, cls.chart)
        (cls.chart / HELD).unlink()  # Test-only assembly; production hold remains.
        result = render(cls.chart, ON)
        if result.returncode:
            raise RuntimeError(result.stderr)
        cls.on = docs(result.stdout)
        cls.union = Union(cls.on)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_off_byte_identical_to_main_and_ignores_control_settings(self):
        # Compare the current main ref, never a pinned SHA or whole-repo grep.
        baseline = self.work / "baseline"
        baseline.mkdir()
        archive = subprocess.run(["git", "archive", os.environ.get("K2_BASE_REF", "origin/main"),
                                  "charts/lucairn"], cwd=ROOT, capture_output=True, timeout=30, check=True)
        archive_file = self.work / "baseline.tar"
        archive_file.write_bytes(archive.stdout)
        with tarfile.open(archive_file) as tar:
            tar.extractall(baseline, filter="data")
        for profile in ["values-test.yaml", "values-dev.yaml"]:
            with self.subTest(profile=profile):
                expected = render(baseline / "charts/lucairn", profile=profile)
                actual = render(CHART, profile=profile)
                ignored = render(CHART, {"global": {"servicenowControl": {
                    "enabled": False, "gatewaySecret": "$(IGNORED)",
                    "sanitizerSecret": None, "instanceCIDRs": ["not-a-cidr"],
                    "kubernetesAPICIDRs": [], "clusterCIDRs": []}}}, profile=profile)
                self.assertEqual(expected.returncode, 0, expected.stderr)
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertEqual(ignored.returncode, 0, ignored.stderr)
                self.assertEqual(actual.stdout, expected.stdout)
                self.assertEqual(ignored.stdout, expected.stdout)
                assembled_off = render(self.chart, profile=profile)
                self.assertEqual(assembled_off.returncode, 0, assembled_off.stderr)
                self.assertEqual(assembled_off.stdout, expected.stdout)

    def test_production_on_is_mechanically_held(self):
        result = render(CHART, ON)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wiring is held", result.stderr)
        for config in [
                {"global": {"servicenowControl": {"enabled": None}}, "gateway": {"global": {"servicenowControl": {"enabled": True}}}},
                {"global": {"servicenowControl": None}, "gateway": {"global": {"servicenowControl": {"enabled": True}}}}]:
            result = render(CHART, config)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("boolean", result.stderr)

    def test_on_private_services_and_no_public_control_exposure(self):
        for name, namespace, port, selector in [
                ("gateway", "dsa-edge", 18443, "gateway"),
                ("sanitizer", "dsa-identity", 18444, "sandbox-a")]:
            service = obj(self.on, "Service", name + "-servicenow-control")
            self.assertEqual(service["metadata"]["namespace"], namespace)
            self.assertEqual(service["spec"]["type"], "ClusterIP")
            self.assertEqual(service["spec"]["selector"], {APP: selector})
            self.assertEqual(service["spec"]["ports"], [{"name": "sn-control", "port": port,
                "targetPort": "sn-control", "protocol": "TCP"}])
        for d in self.on:
            if d["kind"] == "Service":
                control = any(p.get("port") in (18443, 18444) or p.get("targetPort") == "sn-control"
                              for p in d["spec"].get("ports", []))
                if control:
                    self.assertEqual(d["spec"].get("type", "ClusterIP"), "ClusterIP")
                    for key in ["externalIPs", "externalName", "loadBalancerIP"]:
                        self.assertNotIn(key, d["spec"])
                    self.assertTrue(all("nodePort" not in p for p in d["spec"]["ports"]))
            if d["kind"] in ("Ingress", "Gateway", "HTTPRoute", "TCPRoute", "UDPRoute"):
                self.assertNotIn("servicenow-control", json.dumps(d))
            if d["kind"] == "Deployment":
                spec = d["spec"]["template"]["spec"]
                self.assertFalse(spec.get("hostNetwork", False))
                for c in spec["containers"]:
                    self.assertTrue(all(not p.get("hostPort") for p in c.get("ports", [])))

    def test_and_peers_both_directions_and_union_denies_impostors(self):
        self.assertTrue(self.union.reaches(SANITIZER, GATEWAY, 18443))
        self.assertTrue(self.union.reaches(GATEWAY, SANITIZER, 18444))
        for d in self.on:
            if d["kind"] != "NetworkPolicy" or not d["metadata"]["name"].startswith("servicenow-"):
                continue
            if d["metadata"]["name"] == "servicenow-instance-egress":
                continue
            for direction, key in [("ingress", "from"), ("egress", "to")]:
                for rule in d["spec"].get(direction, []):
                    self.assertEqual(len(rule[key]), 1)
                    self.assertIn("namespaceSelector", rule[key][0])
                    self.assertIn("podSelector", rule[key][0])
        for dest, port, allowed in [(GATEWAY, 18443, SANITIZER), (SANITIZER, 18444, GATEWAY)]:
            for namespace in self.union.namespaces:
                for name in ["gateway", "sandbox-a", "id-bridge", "veil-witness", "sandbox-b", "impostor"]:
                    peer = pod(name, namespace)
                    if peer["ns"] == allowed["ns"] and peer["labels"] == allowed["labels"]:
                        continue
                    with self.subTest(peer=peer, port=port):
                        # Destination ingress denies even if the source's egress is unconstrained.
                        self.assertFalse(self.union.allows(dest, peer, "Ingress", port))
                        self.assertFalse(self.union.reaches(peer, dest, port))
        self.assertFalse(self.union.allows(pod("impostor", "dsa-edge"), SANITIZER, "Egress", 18444))
        self.assertFalse(self.union.allows(pod("impostor", "dsa-identity"), GATEWAY, "Egress", 18443))
        self.assertFalse(self.union.allows(GATEWAY, pod("gateway", "dsa-identity"), "Egress", 18444))
        self.assertFalse(self.union.allows(SANITIZER, pod("sandbox-a", "dsa-edge"), "Egress", 18443))

    def test_namespace_blankets_do_not_reopen_control_or_main_sanitize(self):
        for dest, port, peer in [(GATEWAY, 18443, pod("impostor", "dsa-identity")),
                                 (SANITIZER, 18444, pod("impostor", "dsa-edge"))]:
            # Grant arbitrary source egress: existing destination union must still deny.
            self.assertFalse(self.union.allows(dest, peer, "Ingress", port))
        self.assertTrue(self.union.reaches(GATEWAY, SANITIZER, 8086))
        self.assertFalse(self.union.reaches(pod("impostor", "dsa-edge"), SANITIZER, 8086))
        # Existing observability egress lacks 8086; preserve working health on 8083.
        self.assertTrue(self.union.reaches(pod("grafana", "dsa-observability"), SANITIZER, 8083))
        for port in [8083, 50053]:
            self.assertTrue(self.union.reaches(pod("impostor", "dsa-edge"), SANITIZER, port))

    def test_gateway_only_instance_egress_across_all_rendered_workloads(self):
        for config in [ON, merge(ON, {"global": {"llmEgressEnabled": True, "ingestEnabled": True}})]:
            result = render(self.chart, config)
            self.assertEqual(result.returncode, 0, result.stderr)
            items = docs(result.stdout)
            union = Union(items)
            workloads = []
            for d in items:
                if d["kind"] in ["Deployment", "StatefulSet", "DaemonSet", "Job"]:
                    workloads.append({"ns": d["metadata"]["namespace"],
                        "labels": d["spec"]["template"]["metadata"]["labels"]})
            workloads += [pod("impostor", ns) for ns in union.namespaces]
            for ip in ["198.51.100.1", "198.51.100.254", "10.250.0.2"]:
                external = {"ip": ip}
                self.assertTrue(union.allows(GATEWAY, external, "Egress", 443))
                for workload in workloads:
                    if workload["ns"] == "dsa-edge" and workload["labels"].get(APP) == "gateway":
                        continue
                    with self.subTest(workload=workload, ip=ip):
                        self.assertFalse(union.allows(workload, external, "Egress", 443))
            self.assertFalse(union.allows(GATEWAY, {"ip": "198.51.101.1"}, "Egress", 443))
            self.assertFalse(union.allows(GATEWAY, {"ip": "198.51.100.1"}, "Egress", 80))
            self.assertTrue(union.allows(pod("grafana", "dsa-observability"),
                                         {"ip": "192.0.2.1"}, "Egress", 443))

    def test_single_replica_recreate_and_frozen_transport_and_custody(self):
        control = yaml.safe_load(obj(self.on, "ConfigMap", "sanitizer-config")["data"]["config.yaml"])
        sc = control["sanitizer"]["servicenow_instance_path"]
        self.assertIs(sc["enabled"], True)
        self.assertEqual(sc["control_bind_address"], "__LUCAIRN_CONTROL_POD_IP__")
        self.assertEqual(sc["control_expected_peer_dns"], "gateway.servicenow-control")
        self.assertEqual(sc["control_peer_url"], "https://gateway-servicenow-control.dsa-edge.svc.cluster.local:18443")
        for chart, container, workload in [("gateway", "gateway", "gateway"), ("sandbox-a", "sanitizer", "sanitizer")]:
            deploy = obj(self.on, "Deployment", chart)
            self.assertEqual(deploy["spec"]["replicas"], 1)
            self.assertEqual(deploy["spec"]["strategy"], {"type": "Recreate"})
            self.assertFalse(any(d["kind"] == "HorizontalPodAutoscaler" and
                d["spec"]["scaleTargetRef"]["name"] == chart for d in self.on))
            spec = deploy["spec"]["template"]["spec"]
            c = next(c for c in spec["containers"] if c["name"] == container)
            self.assertTrue(c["securityContext"]["readOnlyRootFilesystem"])
            mounts = {v["name"]: v for v in c["volumeMounts"]}
            self.assertEqual(mounts["sn-control-tls"]["mountPath"], "/run/secrets/servicenow-control/" + workload)
            self.assertTrue(mounts["sn-control-tls"]["readOnly"])
            self.assertNotIn("sn-control-source", mounts)
            volumes = {v["name"]: v for v in spec["volumes"]}
            source = volumes["sn-control-source"]["secret"]
            self.assertEqual(source["defaultMode"], 0o400)
            self.assertEqual([i["key"] for i in source["items"]], ["ca.crt", "tls.crt", "tls.key"])
            self.assertEqual(volumes["sn-control-tls"]["emptyDir"]["medium"], "Memory")
            init = next(i for i in spec["initContainers"] if i["name"] == "sn-control-permissions")
            self.assertIn("chmod 0700 /control-tls/leaf", init["args"][0])
            self.assertIn("chmod 0600 /control-tls/leaf/*", init["args"][0])
            self.assertIn("chown -R %s:%s" % (spec["securityContext"]["runAsUser"],
                spec["securityContext"]["runAsGroup"]), init["args"][0])
            launch = obj(self.on, "ConfigMap", chart + "-servicenow-control-launch")["data"]["launch"]
            self.assertTrue(launch.strip())
            env = {v["name"]: v for v in c["env"]}
            if chart == "gateway":
                self.assertEqual(env["GOTRACEBACK"]["value"], "none")
                self.assertEqual(env["GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED"]["value"], "true")
                self.assertEqual(env["GATEWAY_SERVICENOW_CONTROL_BIND_ADDRESS"]["valueFrom"]["fieldRef"]["fieldPath"], "status.podIP")
                self.assertEqual(env["GATEWAY_SERVICENOW_CONTROL_EXPECTED_PEER_DNS"]["value"], "sanitizer.servicenow-control")
                self.assertEqual(env["GATEWAY_SERVICENOW_CONTROL_PEER_URL"]["value"], "https://sanitizer-servicenow-control.dsa-identity.svc.cluster.local:18444")
                for suffix, file in [("CA_CERT", "ca.crt"), ("TLS_CERT", "tls.crt"), ("TLS_KEY", "tls.key")]:
                    self.assertEqual(env["GATEWAY_SERVICENOW_CONTROL_" + suffix]["value"],
                                     "/run/secrets/servicenow-control/gateway/" + file)
                self.assertNotIn("DSA_MTLS_CA_BUNDLE_PATH", env)  # main-channel mesh stays OFF here
                self.assertIn('exec gateway "$@"', launch)
                self.assertIn("ulimit -S -c 0", launch)
                self.assertIn("ulimit -H -c 0", launch)
            else:
                self.assertEqual(volumes["sanitizer-tmp"]["emptyDir"]["medium"], "Memory")
                self.assertEqual(env["LUCAIRN_CONTROL_POD_IP"]["valueFrom"]["fieldRef"]["fieldPath"], "status.podIP")
                self.assertFalse(any(k.startswith("SANITIZER_SERVICENOW") for k in env))
                for key, file in [("control_ca_cert", "ca.crt"), ("control_tls_cert", "tls.crt"), ("control_tls_key", "tls.key")]:
                    self.assertEqual(sc[key], "/run/secrets/servicenow-control/sanitizer/" + file)
                self.assertIn("resource.setrlimit(resource.RLIMIT_CORE, (0, 0))", launch)
                self.assertIn('os.execvp("gunicorn"', launch)

    def test_mesh_and_namespace_overrides_and_global_precedence(self):
        mesh = yaml.safe_load((CHART / "tests/fixtures/enterprise-mtls-accepted.yaml").read_text())
        mesh = merge(mesh, {"global": {"dsaEnv": "development"}})
        result = render(self.chart, merge(mesh, ON))
        self.assertEqual(result.returncode, 0, result.stderr)
        items = docs(result.stdout)
        gateway = obj(items, "Deployment", "gateway")["spec"]["template"]["spec"]["containers"][0]
        self.assertIn("enterprise-mtls", [m["name"] for m in gateway["volumeMounts"]])
        self.assertIn("sn-control-tls", [m["name"] for m in gateway["volumeMounts"]])
        sanitizer = next(c for c in obj(items, "Deployment", "sandbox-a")["spec"]["template"]["spec"]["containers"] if c["name"] == "sanitizer")
        self.assertIn("DSA_MTLS_CA_BUNDLE_PATH", [e["name"] for e in sanitizer["env"]])
        namespaces = yaml.safe_load((CHART / "charts/infrastructure/values.yaml").read_text())["namespaces"]
        for n in namespaces:
            if n["label"] == "edge":
                n["name"] = "synthetic-edge"
            if n["label"] == "identity":
                n["name"] = "synthetic-identity"
        config = merge(ON, {"gateway": {"namespace": "synthetic-edge", "global": {"servicenowControl": {"enabled": False}}},
            "sandbox-a": {"namespace": "synthetic-identity"}, "infrastructure": {"namespaces": namespaces},
            "global": {"servicenowControl": {"gatewayNamespace": "synthetic-edge", "sanitizerNamespace": "synthetic-identity"}}})
        result = render(self.chart, config)
        self.assertEqual(result.returncode, 0, result.stderr)
        items = docs(result.stdout)
        union = Union(items)
        gateway = pod("gateway", "synthetic-edge")
        sanitizer = pod("sandbox-a", "synthetic-identity")
        self.assertTrue(union.reaches(sanitizer, gateway, 18443))
        self.assertTrue(union.reaches(gateway, sanitizer, 18444))
        self.assertTrue(union.reaches(gateway, sanitizer, 8086))
        self.assertEqual(obj(items, "Service", "gateway-servicenow-control")["metadata"]["namespace"], "synthetic-edge")
        control = yaml.safe_load(obj(items, "ConfigMap", "sanitizer-config")["data"]["config.yaml"])["sanitizer"]["servicenow_instance_path"]
        self.assertEqual(control["control_peer_url"], "https://gateway-servicenow-control.synthetic-edge.svc.cluster.local:18443")
        union.namespaces["spoofed"] = {"dsa.io/namespace": "identity", "kubernetes.io/metadata.name": "spoofed"}
        self.assertFalse(union.allows(gateway, pod("sandbox-a", "spoofed"), "Ingress", 18443))
        # A child cannot enable the mode when the umbrella switch is OFF.
        off = render(CHART, {"gateway": {"global": {"servicenowControl": {"enabled": True}}}})
        expected = render(CHART)
        self.assertEqual(off.returncode, 0, off.stderr)
        self.assertEqual(off.stdout, expected.stdout)

    def test_cilium_dns_exact_peers_and_gateway_instance_names(self):
        result = render(self.chart, merge(ON, {"global": {"dnsRestriction": True}}))
        self.assertEqual(result.returncode, 0, result.stderr)
        items = docs(result.stdout)
        expected = {
            "servicenow-gateway-dns": ("gateway", "dsa-edge", {
                "sanitizer-servicenow-control.dsa-identity.svc.cluster.local", "instance.synthetic.test"}),
            "servicenow-sandbox-a-dns": ("sandbox-a", "dsa-identity", {
                "gateway-servicenow-control.dsa-edge.svc.cluster.local"})}
        for name, (app, namespace, names) in expected.items():
            policy = obj(items, "CiliumNetworkPolicy", name)
            self.assertEqual(policy["metadata"]["namespace"], namespace)
            self.assertEqual(policy["spec"]["endpointSelector"], {"matchLabels": {APP: app}})
            egress = policy["spec"]["egress"]
            self.assertEqual(len(egress), 1)
            self.assertEqual(egress[0]["toEndpoints"], [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "kube-system", "k8s-app": "kube-dns"}}])
            port = egress[0]["toPorts"][0]
            self.assertEqual(port["ports"], [{"port": "53", "protocol": "ANY"}])
            self.assertEqual({d["matchName"] for d in port["rules"]["dns"]}, names)
            self.assertTrue(all("matchPattern" not in d for d in port["rules"]["dns"]))

    def test_negative_configs_rejected(self):
        negatives = [
            ({"gateway": {"replicaCount": 2}}, "replicaCount=1"),
            ({"gateway": {"hpa": {"enabled": True}}}, "HPA disabled"),
            ({"sandbox-a": {"replicaCount": 2}}, "replicaCount=1"),
            ({"sandbox-a": {"hpa": {"enabled": True}}}, "HPA disabled"),
            ({"gateway": {"strategy": {"type": "RollingUpdate"}}}, "Recreate"),
            ({"gateway": {"strategy": {"type": "Recreate", "rollingUpdate": {"maxSurge": 1}}}}, "Recreate"),
            ({"gateway": {"securityContext": {"runAsUser": 0}}}, "non-root"),
            ({"gateway": {"service": {"apiPort": 18443}}}, "reserved"),
            ({"sandbox-a": {"service": {"healthPort": 18444}}}, "reserved"),
            ({"gateway": {"containerSecurityContext": {"readOnlyRootFilesystem": False}}}, "read-only root"),
            ({"gateway": {"containerSecurityContext": {"runAsUser": 0}}}, "inherit the pod uid"),
            ({"gateway": {"containerSecurityContext": {"runAsNonRoot": False}}}, "non-root runtime"),
            ({"gateway": {"containerSecurityContext": {"capabilities": {"add": ["SYS_PTRACE"]}}}}, "capabilities"),
            ({"global": {"servicenowControl": {"enabled": "true"}}}, "boolean"),
            ({"global": {"servicenowControl": {"enabled": None}}, "gateway": {"global": {"servicenowControl": {"enabled": True}}}}, "boolean"),
            ({"global": {"dnsRestriction": True, "servicenowControl": {"instanceDNSNames": []}}}, "instanceDNSNames"),
            ({"global": {"dnsRestriction": True, "servicenowControl": {"instanceDNSNames": ["*.synthetic.test"]}}}, "exact lowercase DNS"),
            ({"global": {"servicenowControl": {"gatewaySecret": ""}}}, "existing"),
            ({"global": {"servicenowControl": {"sanitizerSecret": "$(SECRET)"}}}, "existing"),
            ({"global": {"servicenowControl": {"instanceCIDRs": []}}}, "nonempty"),
            ({"global": {"servicenowControl": {"kubernetesAPICIDRs": []}}}, "nonempty"),
            ({"global": {"servicenowControl": {"clusterCIDRs": []}}}, "nonempty"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["0.0.0.0/0"]}}}, "/8 or narrower"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["198.51.100.1/24"]}}}, "canonical"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["999.1.1.1/32"]}}}, "octet"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["127.0.0.1/32"]}}}, "loopback"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["169.254.1.1/32"]}}}, "link-local"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["224.0.0.0/8"]}}}, "multicast"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["2001:db8::/64"]}}}, "IPv6"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["10.244.1.0/24"]}}}, "overlap"),
            ({"global": {"servicenowControl": {"instanceCIDRs": ["10.96.0.0/16"]}}}, "overlap"),
            ({"global": {"servicenowControl": {"gatewayNamespace": "other"}}}, "namespaces"),
            ({"infrastructure": {"enabled": False}}, "infrastructure"),
            ({"gateway": {"enabled": False}}, "requires gateway"),
            ({"sandbox-a": {"enabled": False}}, "requires gateway"),
        ]
        for config, word in negatives:
            with self.subTest(config=config):
                result = render(self.chart, merge(ON, config))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(word, result.stderr)

    def test_launchers_effective_subprocess_core_and_fail_closed(self):
        # A subprocess protects this test runner from irreversible hard-limit changes.
        launcher = CHART / "charts/gateway/files/servicenow-control-launch"
        bindir = self.work / "bin"
        bindir.mkdir(exist_ok=True)
        fake = bindir / "gateway"
        fake.write_text('#!/usr/bin/env python3\nimport resource,sys\nassert resource.getrlimit(resource.RLIMIT_CORE)==(0,0)\nassert sys.argv[1:]==["synthetic-arg"]\nprint("core_0_0")\n')
        fake.chmod(0o700)  # Temporary fixture only.
        env = {**os.environ, "PATH": str(bindir) + os.pathsep + os.environ["PATH"]}
        result = subprocess.run(["/bin/sh", str(launcher), "synthetic-arg"], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "core_0_0")
        fail = subprocess.run(["/bin/sh", "-c", 'ulimit() { return 1; }; . "$1"',
                               "test", str(launcher)], env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(fail.returncode, 0)
        self.assertNotIn("core_0_0", fail.stdout)
        bad_ip = "synthetic-invalid-private-address"
        failed = subprocess.run(["python3", "-B", str(CHART / "charts/sandbox-a/files/servicenow-control-launch")],
            env={**os.environ, "LUCAIRN_CONTROL_POD_IP": bad_ip}, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(failed.stderr, "control_unavailable\n")
        self.assertNotIn(bad_ip, failed.stderr)
        # The sanitizer's prepare function is exercised with synthetic in-memory YAML.
        path = CHART / "charts/sandbox-a/files/servicenow-control-launch"
        loader = importlib.machinery.SourceFileLoader("k2_sanitizer_launch", str(path))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        config = obj(self.on, "ConfigMap", "sanitizer-config")["data"]["config.yaml"]
        config_dir = self.work / "sanitizer-launch"
        config_dir.mkdir()
        source = config_dir / "input.yaml"
        source.write_text(config)
        script = r'''import importlib.machinery, importlib.util, json, os, pathlib, resource, sys
loader=importlib.machinery.SourceFileLoader("launch",sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)
base=pathlib.Path(sys.argv[2])
def path(value):
    return base/"input.yaml" if value=="/config/config.yaml" else base/"runtime"
m.Path=path
os.environ["LUCAIRN_CONTROL_POD_IP"]="10.244.0.2"
m.prepare()
assert resource.getrlimit(resource.RLIMIT_CORE)==(0,0)
assert (base/"runtime").stat().st_mode & 0o777 == 0o700
assert (base/"runtime/config.yaml").stat().st_mode & 0o777 == 0o600
assert m.yaml.safe_load((base/"runtime/config.yaml").read_text())["sanitizer"]["servicenow_instance_path"]["control_bind_address"]=="10.244.0.2"
print("sanitizer_core_0_0_config_private")
'''
        child = subprocess.run(["python3", "-B", "-c", script, str(path), str(config_dir)],
                               capture_output=True, text=True, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(child.stdout.strip(), "sanitizer_core_0_0_config_private")
        for ip, permitted in [("10.244.0.2", True), ("100.64.0.2", True),
                ("0.0.0.0", False), ("127.0.0.1", False), ("169.254.0.2", False),
                ("8.8.8.8", False), ("::", False), ("::1", False), ("bad", False)]:
            with self.subTest(ip=ip), mock.patch.dict(os.environ, {"LUCAIRN_CONTROL_POD_IP": ip}), \
                    mock.patch.object(module.resource, "setrlimit") as setlimit, \
                    mock.patch.object(module.resource, "getrlimit", return_value=(0, 0)), \
                    mock.patch.object(module, "Path") as path_class, \
                    mock.patch.object(module.os, "chmod"), \
                    mock.patch("builtins.open") as file_open:
                source, targetdir = mock.MagicMock(), mock.MagicMock()
                source.read_text.return_value = config
                path_class.side_effect = [source, targetdir]
                if permitted:
                    module.prepare()
                    output = file_open.return_value.__enter__.return_value
                    written = "".join(c.args[0] for c in output.write.call_args_list)
                    self.assertEqual(yaml.safe_load(written)["sanitizer"]["servicenow_instance_path"]["control_bind_address"], ip)
                else:
                    with self.assertRaises((ValueError, KeyError)):
                        module.prepare()
                    path_class.assert_not_called()
                setlimit.assert_called_once_with(module.resource.RLIMIT_CORE, (0, 0))
        with mock.patch.object(module.resource, "setrlimit"), \
                mock.patch.object(module.resource, "getrlimit", return_value=(1, 1)), \
                mock.patch.object(module, "Path") as path_class:
            with self.assertRaisesRegex(ValueError, "core_limit"):
                module.prepare()
            path_class.assert_not_called()


if __name__ == "__main__":
    unittest.main()
