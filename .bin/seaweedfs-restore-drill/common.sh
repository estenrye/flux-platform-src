# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here are used by the scripts that source this file
# Shared setup for the SeaweedFS restore drill scripts (source this; do not run it).
# See docs/runbooks/seaweedfs-db-restore.md, Part D.
set -u
DRILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${DRILL_DIR}/../.." && pwd)"
# Cluster access: KUBECONFIG if set, else the path in the core-infra catalog annotation (repo convention).
if [ -z "${KUBECONFIG:-}" ]; then
  KUBECONFIG="$(yq e '.metadata.annotations["rye.ninja/kubeconfig"]' "${REPO_ROOT}/clusters/core-infra/catalog.yaml")"
  KUBECONFIG="${KUBECONFIG/#\~/$HOME}"
fi
export KUBECONFIG
NS=seaweedfs
# State and scratch files (no credentials are ever written here).
WORK="${WORK:-/tmp/seaweedfs-restore-drill-$(id -u)}"
umask 077; mkdir -p "${WORK}"
# Optional: admin access to OpenStack, used only to confirm Cinder snapshots are really gone.
OPENSTACK_SSH="${OPENSTACK_SSH:-ubuntu@pcd.rye.ninja}"
IMAGE_PG='ghcr.io/cloudnative-pg/postgresql:18.3@sha256:5e30290fba3d990b08a9caea6ddb49c661ad8246cbb2688adad7e6cc78df6c3f'

log() { echo "[$(date -u +%T)] $*"; }
OS() { ssh -o BatchMode=yes -o ConnectTimeout=10 "${OPENSTACK_SSH}" "sudo bash -c 'source /root/openstackrc; $*'" 2>&1; }
# Number of non-drill pods in the namespace that are not fully ready (Completed jobs ignored).
prod_not_ready() { kubectl -n "${NS}" get pods --no-headers | grep -v Completed | grep -v '^drill' | awk '{split($2,a,"/"); if (a[1]!=a[2]) n++} END{print n+0}'; }
health() { echo "pods not ready: $(prod_not_ready); cnpg: $(kubectl -n "${NS}" get cluster.postgresql.cnpg.io seaweedfs-db -o jsonpath='{.status.readyInstances}/{.spec.instances}')"; }
s3_creds() { # export admin credentials for aws; never printed
  AWS_ACCESS_KEY_ID="$(kubectl -n "${NS}" get secret seaweedfs-s3-config -o jsonpath='{.data.admin-access-key-id}' | base64 -d)"
  AWS_SECRET_ACCESS_KEY="$(kubectl -n "${NS}" get secret seaweedfs-s3-config -o jsonpath='{.data.admin-secret-access-key}' | base64 -d)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=us-east-1 AWS_PAGER=""
}
wait_http() { for _ in $(seq 1 20); do curl -s -o /dev/null --max-time 2 "$1" && return 0; sleep 1; done; return 1; }
