#!/bin/bash
set -e
SCRIPTS_DIR=$(cd "$(dirname "$0")/../.." && pwd)
TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

# Set up a fake cluster directory with a real age key and a SOPS-encrypted file
CLUSTER_NAME="test-cluster"
CLUSTER_DIR="${TEMP_DIR}/clusters/${CLUSTER_NAME}"
mkdir -p "${CLUSTER_DIR}/resources"

# Generate a real age key for the test
age-keygen -o "${CLUSTER_DIR}/.sops.age-key" 2>/dev/null
OLD_PUBLIC_KEY=$(age-keygen -y "${CLUSTER_DIR}/.sops.age-key")

# Write .sops.yaml using the generated key
cat > "${CLUSTER_DIR}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: .*.yaml
    encrypted_regex: ^(data|stringData)$
    age: >-
      ${OLD_PUBLIC_KEY}
EOF

# Create and encrypt a test secret using the old key
TMPFILE=$(mktemp /tmp/test-secret-XXXXXX.yaml)
cat > "${TMPFILE}" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: test-secret
  namespace: default
type: Opaque
stringData:
  token: supersecret
EOF
SOPS_AGE_KEY_FILE="${CLUSTER_DIR}/.sops.age-key" \
  sops --encrypt \
  --config "${CLUSTER_DIR}/.sops.yaml" \
  --input-type yaml --output-type yaml \
  "${TMPFILE}" > "${CLUSTER_DIR}/resources/test-secret.yaml"
rm -f "${TMPFILE}"

# Confirm the file is encrypted
grep -q "ENC\[" "${CLUSTER_DIR}/resources/test-secret.yaml" || \
  { echo "FAIL: test-secret.yaml not encrypted"; exit 1; }

# Record old public key for later comparison
OLD_KEY_CONTENT=$(cat "${CLUSTER_DIR}/.sops.age-key")

# Stub out the op, kubectl, git, and push calls that require live services
export PATH="${TEMP_DIR}/bin:${PATH}"
mkdir -p "${TEMP_DIR}/bin"

# Stub: op (returns the old private key for the read, exits ok for write)
cat > "${TEMP_DIR}/bin/op" <<STUB
#!/bin/bash
if [[ "\$*" == *"get"*"sops-age-key"* ]]; then
  cat "${CLUSTER_DIR}/.sops.age-key"
elif [[ "\$*" == *"edit"* ]]; then
  exit 0
fi
STUB
chmod +x "${TEMP_DIR}/bin/op"

# Stub: kubectl (exits ok)
cat > "${TEMP_DIR}/bin/kubectl" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "${TEMP_DIR}/bin/kubectl"

# Stub: git (exits ok, no-op)
cat > "${TEMP_DIR}/bin/git" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "${TEMP_DIR}/bin/git"

# Run the rotation script with CLUSTER_PATH, CLUSTER_DIR, CLUSTER_NAME,
# REPO_ROOT, KUBECONFIG injected to bypass lib helper sourcing
CLUSTER_PATH="${CLUSTER_DIR}" \
CLUSTER_DIR="clusters/${CLUSTER_NAME}" \
CLUSTER_NAME="${CLUSTER_NAME}" \
REPO_ROOT="${TEMP_DIR}" \
KUBECONFIG="/dev/null" \
  bash "${SCRIPTS_DIR}/.bin/rotate-cluster-sops-key.sh" 2>/dev/null

# Assert: .sops.yaml now contains a different public key
NEW_PUBLIC_KEY=$(age-keygen -y "${CLUSTER_DIR}/.sops.age-key")
[ "${NEW_PUBLIC_KEY}" != "${OLD_PUBLIC_KEY}" ] || \
  { echo "FAIL: public key was not rotated"; exit 1; }

grep -q "${NEW_PUBLIC_KEY}" "${CLUSTER_DIR}/.sops.yaml" || \
  { echo "FAIL: .sops.yaml not updated with new public key"; exit 1; }

# Assert: encrypted file can be decrypted with the NEW key
DECRYPTED=$(SOPS_AGE_KEY_FILE="${CLUSTER_DIR}/.sops.age-key" \
  sops --decrypt \
  --input-type yaml --output-type yaml \
  "${CLUSTER_DIR}/resources/test-secret.yaml" 2>/dev/null)

echo "${DECRYPTED}" | grep -q "supersecret" || \
  { echo "FAIL: re-encrypted file cannot be decrypted with new key"; exit 1; }

echo "PASS: rotate-cluster-sops-key"
