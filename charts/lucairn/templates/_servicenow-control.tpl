{{/* Render helpers for Slice 3. The held template blocks production ON renders. */}}
{{- define "servicenowControl.enabled" -}}
{{- $global := .Values.global | default dict -}}
{{- $c := get $global "servicenowControl" | default dict -}}
{{- if hasKey $c "enabled" -}}
{{- if not (kindIs "bool" $c.enabled) -}}{{- fail "servicenowControl.enabled must be boolean" -}}{{- end -}}
{{- if $c.enabled -}}
{{- if and (ne .Chart.Name "lucairn") (not (contains "/charts/" .Template.BasePath)) -}}
{{- fail "ServiceNow control requires the umbrella chart; standalone subchart enablement is unsupported" -}}
{{- end -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* IPv4 only: reject unsupported families rather than render an unchecked CIDR. */}}
{{- define "servicenowControl.cidr" -}}
{{- if not (kindIs "string" .) -}}{{- fail "ServiceNow CIDR must be an IPv4 CIDR string" -}}{{- end -}}
{{- if not (regexMatch `^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$` .) -}}
{{- fail "ServiceNow CIDR must be a canonical IPv4 CIDR; IPv6 CIDRs are not supported by this chart guard" -}}
{{- end -}}
{{- $parts := splitList "/" . -}}{{- $ip := int64 0 -}}
{{- range splitList "." (index $parts 0) -}}
{{- if or (gt (int .) 255) (ne (toString (int .)) .) -}}{{- fail "ServiceNow CIDR has an invalid IPv4 octet" -}}{{- end -}}
{{- $ip = add (mul $ip 256) (int64 .) -}}
{{- end -}}
{{- $prefix := int (index $parts 1) -}}
{{- if lt $prefix 8 -}}{{- fail "ServiceNow CIDRs must be /8 or narrower" -}}{{- end -}}
{{- $size := int64 1 -}}{{- range until (sub 32 $prefix | int) -}}{{- $size = mul $size 2 -}}{{- end -}}
{{- if ne (mod $ip $size) (int64 0) -}}{{- fail "ServiceNow CIDR must use its canonical network address" -}}{{- end -}}
{{- dict "start" $ip "end" (sub (add $ip $size) 1) | toJson -}}
{{- end -}}

{{- define "servicenowControl.validate" -}}
{{- $enabled := include "servicenowControl.enabled" . -}}
{{- $c := .Values.global.servicenowControl | default dict -}}
{{- if not (kindIs "bool" $c.enabled) -}}{{- fail "servicenowControl.enabled must be boolean, including when disabled" -}}{{- end -}}
{{- if $enabled -}}
{{- range $name := list "gateway" "sandbox-a" "infrastructure" "sandbox-b" "veil-witness" -}}
{{- if (index $.Values $name).enabled -}}
{{- $child := index $.Values $name | default dict -}}
{{- $cg := get $child "global" | default dict -}}
{{- if ne (toJson (get $cg "servicenowControl" | default dict)) (toJson $c) -}}
{{- fail "servicenowControl must be set at umbrella global scope; subchart overrides are not supported" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $enabled -}}
{{- range $name := list "gateway" "sandbox-a" "infrastructure" -}}
{{- if not (index $.Values $name).enabled -}}{{- fail "ServiceNow control requires gateway, sandbox-a and infrastructure enabled" -}}{{- end -}}
{{- end -}}
{{- if or (ne $c.gatewayNamespace .Values.gateway.namespace) (ne $c.sanitizerNamespace (index .Values "sandbox-a").namespace) -}}
{{- fail "ServiceNow control namespaces must match gateway and sandbox-a namespaces" -}}{{- end -}}
{{- range $name := list "gatewaySecret" "sanitizerSecret" -}}
{{- $value := get $c $name -}}
{{- if or (not (kindIs "string" $value)) (not (regexMatch `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` $value)) (gt (len $value) 63) -}}
{{- fail "ServiceNow control requires valid existing gatewaySecret and sanitizerSecret names" -}}
{{- end -}}
{{- end -}}
{{- range $name := list "instanceCIDRs" "kubernetesAPICIDRs" "clusterCIDRs" -}}
{{- $cidrs := get $c $name -}}
{{- if or (not (kindIs "slice" $cidrs)) (empty $cidrs) -}}{{- fail "ServiceNow control requires nonempty instanceCIDRs, kubernetesAPICIDRs and clusterCIDRs" -}}{{- end -}}
{{- range $cidrs -}}{{- $_ := include "servicenowControl.cidr" . -}}{{- end -}}
{{- end -}}
{{- if .Values.global.dnsRestriction -}}
{{- if or (not (kindIs "slice" $c.instanceDNSNames)) (empty $c.instanceDNSNames) -}}{{- fail "ServiceNow control with dnsRestriction requires instanceDNSNames" -}}{{- end -}}
{{- range $c.instanceDNSNames -}}
{{- if or (not (kindIs "string" .)) (gt (len .) 253) (not (regexMatch `^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` .)) -}}
{{- fail "ServiceNow instanceDNSNames must contain exact lowercase DNS names" -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- range $instance := $c.instanceCIDRs -}}
{{- $a := include "servicenowControl.cidr" $instance | fromJson -}}
{{- if or (lt (int64 $a.start) 16777216) (ge (int64 $a.start) 3758096384) (and (le (int64 $a.start) 2147483647) (ge (int64 $a.end) 2130706432)) (and (le (int64 $a.start) 2852061183) (ge (int64 $a.end) 2851995648)) -}}
{{- fail "ServiceNow instance CIDRs cannot cover loopback, link-local, multicast or reserved ranges" -}}
{{- end -}}
{{- range concat $c.kubernetesAPICIDRs $c.clusterCIDRs -}}
{{- $b := include "servicenowControl.cidr" . | fromJson -}}
{{- if and (le (int64 $a.start) (int64 $b.end)) (le (int64 $b.start) (int64 $a.end)) -}}
{{- fail "ServiceNow instance CIDRs must not overlap API, Pod or Service CIDRs" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $key := list "grpcPort" "healthPort" -}}
{{- if has (int (get (index $.Values "sandbox-a").service $key)) (list 18443 18444) -}}{{- fail "ordinary sandbox-a ports cannot use reserved ServiceNow control ports" -}}{{- end -}}
{{- end -}}
{{- range $key := list "apiPort" "healthPort" -}}
{{- if has (int (get $.Values.gateway.service $key)) (list 18443 18444) -}}{{- fail "ordinary gateway ports cannot use reserved ServiceNow control ports" -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.workloadValidate" -}}
{{- if include "servicenowControl.enabled" . -}}
{{- if or (ne (toString .Values.replicaCount) "1") .Values.hpa.enabled -}}
{{- fail "ServiceNow control requires replicaCount=1 and HPA disabled" -}}{{- end -}}
{{- $security := .Values.containerSecurityContext -}}
{{- if or (not $security.readOnlyRootFilesystem) $security.allowPrivilegeEscalation $security.privileged (not (has "ALL" $security.capabilities.drop)) (not (empty $security.capabilities.add)) -}}
{{- fail "ServiceNow control requires read-only root, no privilege escalation and all capabilities dropped" -}}{{- end -}}
{{- range $key := list "runAsUser" "runAsGroup" -}}
{{- if and (hasKey $security $key) (ne (toString (get $security $key)) (toString (get $.Values.securityContext $key))) -}}
{{- fail "ServiceNow containers must inherit the pod uid and gid used for TLS ownership" -}}{{- end -}}
{{- end -}}
{{- if and (hasKey $security "runAsNonRoot") (not $security.runAsNonRoot) -}}
{{- fail "ServiceNow containers require non-root runtime identity" -}}{{- end -}}
{{- if hasKey .Values "strategy" -}}
{{- if ne (toJson .Values.strategy) (toJson (dict "type" "Recreate")) -}}
{{- fail "ServiceNow control requires Recreate with no rollingUpdate settings" -}}{{- end -}}
{{- end -}}
{{- if or (not .Values.securityContext.runAsNonRoot) (lt (int .Values.securityContext.runAsUser) 1) (lt (int .Values.securityContext.runAsGroup) 1) -}}
{{- fail "ServiceNow control requires explicit non-root pod uid and gid" -}}{{- end -}}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.instanceExcept" -}}
{{- if include "servicenowControl.enabled" . -}}
{{- range .Values.global.servicenowControl.instanceCIDRs }}
- {{ . | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.workload" -}}
{{- if eq .Chart.Name "gateway" -}}gateway{{- else -}}sanitizer{{- end -}}
{{- end -}}

{{- define "servicenowControl.command" -}}
{{- if include "servicenowControl.enabled" . }}
command: {{ if eq .Chart.Name "gateway" }}["/bin/sh", "/opt/lucairn/servicenow-control/launch"]{{ else }}["python3", "/opt/lucairn/servicenow-control/launch"]{{ end }}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.port" -}}
{{- if include "servicenowControl.enabled" . }}
- name: sn-control
  containerPort: {{ if eq .Chart.Name "gateway" }}18443{{ else }}18444{{ end }}
  protocol: TCP
{{- end -}}
{{- end -}}

{{- define "servicenowControl.gatewayEnv" -}}
{{- if include "servicenowControl.enabled" . }}
- name: GATEWAY_SERVICENOW_INSTANCE_PATH_ENABLED
  value: "true"
- name: GATEWAY_SERVICENOW_CONTROL_BIND_ADDRESS
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: GATEWAY_SERVICENOW_CONTROL_PEER_URL
  value: {{ printf "https://sanitizer-servicenow-control.%s.svc.cluster.local:18444" .Values.global.servicenowControl.sanitizerNamespace | quote }}
- name: GATEWAY_SERVICENOW_CONTROL_CA_CERT
  value: /run/secrets/servicenow-control/gateway/ca.crt
- name: GATEWAY_SERVICENOW_CONTROL_TLS_CERT
  value: /run/secrets/servicenow-control/gateway/tls.crt
- name: GATEWAY_SERVICENOW_CONTROL_TLS_KEY
  value: /run/secrets/servicenow-control/gateway/tls.key
- name: GATEWAY_SERVICENOW_CONTROL_EXPECTED_PEER_DNS
  value: sanitizer.servicenow-control
- name: GOTRACEBACK
  value: none
{{- end -}}
{{- end -}}

{{- define "servicenowControl.sanitizerConfig" -}}
{{- if include "servicenowControl.enabled" . }}
servicenow_instance_path:
  enabled: true
  assertion_posture: block
  entropy_id_release: retain
  typed_text_threshold: 2000
  servicenow_mcp_server: ""
  control_bind_address: __LUCAIRN_CONTROL_POD_IP__
  control_peer_url: {{ printf "https://gateway-servicenow-control.%s.svc.cluster.local:18443" .Values.global.servicenowControl.gatewayNamespace | quote }}
  control_ca_cert: /run/secrets/servicenow-control/sanitizer/ca.crt
  control_tls_cert: /run/secrets/servicenow-control/sanitizer/tls.crt
  control_tls_key: /run/secrets/servicenow-control/sanitizer/tls.key
  control_expected_peer_dns: gateway.servicenow-control
{{- end -}}
{{- end -}}

{{- define "servicenowControl.mounts" -}}
{{- if include "servicenowControl.enabled" . }}
- name: sn-control-launch
  mountPath: /opt/lucairn/servicenow-control
  readOnly: true
- name: sn-control-tls
  mountPath: /run/secrets/servicenow-control/{{ include "servicenowControl.workload" . }}
  subPath: leaf
  readOnly: true
{{- end -}}
{{- end -}}

{{- define "servicenowControl.volumes" -}}
{{- if include "servicenowControl.enabled" . }}
- name: sn-control-launch
  configMap:
    name: {{ .Chart.Name }}-servicenow-control-launch
    defaultMode: 0444
- name: sn-control-tls
  emptyDir:
    medium: Memory
    sizeLimit: 1Mi
- name: sn-control-source
  secret:
    secretName: {{ if eq .Chart.Name "gateway" }}{{ .Values.global.servicenowControl.gatewaySecret }}{{ else }}{{ .Values.global.servicenowControl.sanitizerSecret }}{{ end }}
    defaultMode: 0400
    items:
      - {key: ca.crt, path: ca.crt}
      - {key: tls.crt, path: tls.crt}
      - {key: tls.key, path: tls.key}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.init" -}}
{{- if include "servicenowControl.enabled" . }}
- name: sn-control-permissions
  image: "{{ if .Values.global.imageRegistry }}{{ .Values.global.imageRegistry }}/{{ end }}{{ if eq .Chart.Name "gateway" }}{{ .Values.image.repository }}:{{ .Values.image.tag | default .Values.global.imageTag | default .Chart.AppVersion }}{{ else }}{{ .Values.sanitizer.image.repository }}:{{ .Values.sanitizer.image.tag | default .Values.global.imageTag | default .Chart.AppVersion }}{{ end }}"
  command: ["/bin/sh", "-ec"]
  args:
    - |
      umask 077
      mkdir -p /control-tls/leaf
      cp /source/ca.crt /source/tls.crt /source/tls.key /control-tls/leaf/
      chmod 0700 /control-tls/leaf
      chmod 0600 /control-tls/leaf/*
      chown -R {{ .Values.securityContext.runAsUser }}:{{ .Values.securityContext.runAsGroup }} /control-tls/leaf
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    runAsNonRoot: false
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: [ALL]
      add: [CHOWN]
  volumeMounts:
    - {name: sn-control-source, mountPath: /source, readOnly: true}
    - {name: sn-control-tls, mountPath: /control-tls}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.resources" -}}
{{- if include "servicenowControl.enabled" . -}}
{{- $workload := include "servicenowControl.workload" . -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $workload }}-servicenow-control
  namespace: {{ .Values.namespace }}
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: {{ .Chart.Name }}
  ports:
    - name: sn-control
      port: {{ if eq $workload "gateway" }}18443{{ else }}18444{{ end }}
      targetPort: sn-control
      protocol: TCP
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Chart.Name }}-servicenow-control-launch
  namespace: {{ .Values.namespace }}
data:
  launch: |
{{ .Files.Get "files/servicenow-control-launch" | indent 4 }}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.policies" -}}
{{- if include "servicenowControl.enabled" . -}}
{{- $edge := include "infrastructure.namespaceFor" (dict "root" . "label" "edge") -}}
{{- $identity := include "infrastructure.namespaceFor" (dict "root" . "label" "identity") -}}
{{- $flows := list
  (dict "source" "gateway" "sourceNS" $edge "sourceLabel" "edge" "dest" "sandbox-a" "destNS" $identity "destLabel" "identity" "port" 18444)
  (dict "source" "sandbox-a" "sourceNS" $identity "sourceLabel" "identity" "dest" "gateway" "destNS" $edge "destLabel" "edge" "port" 18443)
  (dict "source" "gateway" "sourceNS" $edge "sourceLabel" "edge" "dest" "sandbox-a" "destNS" $identity "destLabel" "identity" "port" 8086) -}}
{{- range $flow := $flows }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: servicenow-{{ $flow.source }}-{{ $flow.port }}-egress
  namespace: {{ $flow.sourceNS }}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $flow.source }}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ $flow.destNS }}
              dsa.io/namespace: {{ $flow.destLabel }}
          podSelector:
            matchLabels:
              app.kubernetes.io/name: {{ $flow.dest }}
      ports:
        - {port: {{ $flow.port }}, protocol: TCP}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: servicenow-{{ $flow.source }}-{{ $flow.port }}-ingress
  namespace: {{ $flow.destNS }}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $flow.dest }}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ $flow.sourceNS }}
              dsa.io/namespace: {{ $flow.sourceLabel }}
          podSelector:
            matchLabels:
              app.kubernetes.io/name: {{ $flow.source }}
      ports:
        - {port: {{ $flow.port }}, protocol: TCP}
{{- end }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: servicenow-instance-egress
  namespace: {{ $edge }}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: gateway
  policyTypes: [Egress]
  egress:
    - to:
{{- range .Values.global.servicenowControl.instanceCIDRs }}
        - ipBlock:
            cidr: {{ . | quote }}
{{- end }}
      ports:
        - {port: 443, protocol: TCP}
{{- end -}}
{{- end -}}

{{- define "servicenowControl.dns" -}}
{{- if and (include "servicenowControl.enabled" .) .Values.global.dnsRestriction -}}
{{- $edge := include "infrastructure.namespaceFor" (dict "root" . "label" "edge") -}}
{{- $identity := include "infrastructure.namespaceFor" (dict "root" . "label" "identity") -}}
{{- $gatewayNames := concat (list (printf "sanitizer-servicenow-control.%s.svc.cluster.local" $identity)) .Values.global.servicenowControl.instanceDNSNames -}}
{{- range $peer := list (dict "pod" "gateway" "namespace" $edge "names" $gatewayNames) (dict "pod" "sandbox-a" "namespace" $identity "names" (list (printf "gateway-servicenow-control.%s.svc.cluster.local" $edge))) }}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: servicenow-{{ $peer.pod }}-dns
  namespace: {{ $peer.namespace }}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $peer.pod }}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - {port: "53", protocol: ANY}
          rules:
            dns:
{{- range $peer.names }}
              - matchName: {{ . | quote }}
{{- end }}
{{- end -}}
{{- end -}}
{{- end -}}
