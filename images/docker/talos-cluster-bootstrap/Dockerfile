# M4 step 2: Talos-bootstrap tooling image. Bundles the binaries
# .bin/create-controlplane-cluster.sh's imperative half needs (talosctl,
# bao, jq, curl) plus kubectl (to write the connection secret -- this Job
# runs in-cluster, not on a workstation, so "kubeconfig to a file" becomes
# "kubeconfig to a K8s Secret") and yq (machine-config YAML manipulation).
#
# Every version below is pinned to match this fleet's existing pins
# (providers/kvm/versions.yaml for talosctl/kubectl; OpenBao server is
# openbao-helm app v2.6.1 per docs/memory/m3-step-tracker.md) and verified
# against each project's own published checksum file at build time -- no
# hardcoded hash is trusted blindly.
FROM alpine:3.22 AS fetch
RUN apk add --no-cache curl
WORKDIR /out

ARG TALOSCTL_VERSION=v1.13.5
RUN curl -fsSL -O "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/talosctl-linux-amd64" \
 && curl -fsSL -o sha256sum.txt "https://github.com/siderolabs/talos/releases/download/${TALOSCTL_VERSION}/sha256sum.txt" \
 && grep "talosctl-linux-amd64\$" sha256sum.txt | sha256sum -c - \
 && mv talosctl-linux-amd64 talosctl \
 && chmod +x talosctl \
 && rm sha256sum.txt

ARG KUBECTL_VERSION=v1.36.2
RUN curl -fsSL -o kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && curl -fsSL -o kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
 && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - \
 && chmod +x kubectl \
 && rm kubectl.sha256

ARG JQ_VERSION=jq-1.8.2
RUN curl -fsSL -O "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64" \
 && curl -fsSL -o sha256sum.txt "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/sha256sum.txt" \
 && grep "jq-linux-amd64\$" sha256sum.txt | sha256sum -c - \
 && mv jq-linux-amd64 jq \
 && chmod +x jq \
 && rm sha256sum.txt

# mikefarah/yq's release "checksums" file is a multi-algorithm CSV, not a
# plain sha256sum.txt -- SHA-256 is column 19 (whitespace-delimited,
# filename in column 1), per that release's own "checksums_hashes_order"
# asset (CRC32, MD4, MD5, SHA1, TIGER, TTH, BTIH, ED2K, AICH, WHIRLPOOL,
# RIPEMD-160, GOST94, GOST94-CRYPTOPRO, HAS-160, GOST12-256, GOST12-512,
# SHA-224, SHA-256, ...). Verified against a live pull of that file
# 2026-07-28, not assumed from memory.
ARG YQ_VERSION=v4.53.3
RUN curl -fsSL -o yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
 && curl -fsSL -o checksums "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums" \
 && expected="$(grep '^yq_linux_amd64 ' checksums | awk '{print $19}')" \
 && actual="$(sha256sum yq | awk '{print $1}')" \
 && [ "${expected}" = "${actual}" ] || { echo "yq checksum mismatch: expected ${expected}, got ${actual}"; exit 1; } \
 && chmod +x yq \
 && rm checksums

ARG OPENBAO_VERSION=2.6.1
RUN curl -fsSL -O "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz" \
 && curl -fsSL -o checksums.txt "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/checksums.txt" \
 && grep "openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz\$" checksums.txt | sha256sum -c - \
 && tar -xzf "openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz" bao \
 && chmod +x bao \
 && rm "openbao_${OPENBAO_VERSION}_linux_amd64.tar.gz" checksums.txt

FROM alpine:3.22
RUN apk add --no-cache bash curl ca-certificates
COPY --from=fetch /out/talosctl /out/kubectl /out/jq /out/yq /out/bao /usr/local/bin/
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod +x /usr/local/bin/bootstrap.sh
ENTRYPOINT ["/usr/local/bin/bootstrap.sh"]
