#!/bin/bash
# Step 2: take the coordinated set from PRODUCTION (database backup FIRST, then the volume snapshot), restore both into a
# scratch stack (drill-db, drill-volume, drill-master/-volume/-filer) in the same namespace, and wait until it is up.
# Needs the state written by seed.sh. Nothing here writes to the production database, volumes or masters.
source "$(dirname "$0")/common.sh"
cd "${WORK}" || exit 1
source state.env
STAMP=$(date -u +%Y%m%dt%H%M%Sz)   # lowercase: used in Kubernetes names
SNAP="rd-${STAMP}"
log "pre-flight: $(health)"
[ "$(prod_not_ready)" = "0" ] || { log "ABORT: SeaweedFS is not fully healthy"; exit 1; }
kubectl get volumesnapshotclass csi-cinder-snapclass-delete-inuse >/dev/null || { log "ABORT: snapshot class csi-cinder-snapclass-delete-inuse missing (apply pcd-ce-deploy)"; exit 1; }

# 1. metadata first
cat <<YAMLEND | kubectl apply -f - >/dev/null || { log "ABORT: Backup not created"; exit 1; }
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: {name: seaweedfs-db-set-${STAMP}, namespace: ${NS}, labels: {rye.ninja/purpose: seaweedfs-restore-drill}}
spec: {cluster: {name: seaweedfs-db}, method: plugin, pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}}
YAMLEND
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=completed "backup/seaweedfs-db-set-${STAMP}" --timeout=900s >/dev/null 2>&1 \
  && log "database backup seaweedfs-db-set-${STAMP} completed" \
  || { log "ABORT: backup did not complete: $(kubectl -n "${NS}" get backup "seaweedfs-db-set-${STAMP}" -o jsonpath='{.status.phase} {.status.error}')"; exit 1; }

# 2. then the data: the volume server holding a replica of the audit object's volume (${SRC_PVC})
cat <<YAMLEND | kubectl apply -f - >/dev/null || { log "ABORT: VolumeSnapshot not created"; exit 1; }
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata: {name: ${SNAP}, namespace: ${NS}, labels: {rye.ninja/purpose: seaweedfs-restore-drill}}
spec: {volumeSnapshotClassName: csi-cinder-snapclass-delete-inuse, source: {persistentVolumeClaimName: ${SRC_PVC}}}
YAMLEND
if kubectl -n "${NS}" wait --for=jsonpath='{.status.readyToUse}'=true "volumesnapshot/${SNAP}" --timeout=600s >/dev/null 2>&1; then
  log "snapshot ${SNAP} of ${SRC_PVC} ready (restoreSize $(kubectl -n "${NS}" get volumesnapshot "${SNAP}" -o jsonpath='{.status.restoreSize}'))"
else
  log "ABORT: snapshot not ready: $(kubectl -n "${NS}" get volumesnapshot "${SNAP}" -o jsonpath='{.status.error.message}' | cut -c1-250)"; exit 1
fi
log "production after the snapshot: $(health)"
echo "SNAP=${SNAP}" > restore.env

# 3. restores
cat <<YAMLEND | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: drill-volume, namespace: ${NS}, labels: {rye.ninja/purpose: seaweedfs-restore-drill}}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: csi-cinder-sc-delete
  resources: {requests: {storage: 100Gi}}
  dataSource: {name: ${SNAP}, kind: VolumeSnapshot, apiGroup: snapshot.storage.k8s.io}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: drill-db, namespace: ${NS}, labels: {rye.ninja/purpose: seaweedfs-restore-drill}}
spec:
  instances: 1
  imageName: ${IMAGE_PG}
  postgresql: {parameters: {max_connections: "200"}}
  storage: {size: 10Gi, storageClass: csi-cinder-sc-delete}
  # No spec.plugins block: the scratch cluster must never archive WAL into production's path.
  bootstrap:
    recovery:
      source: seaweedfs-db-source
      database: seaweedfs
      owner: seaweedfs
  externalClusters:
    - name: seaweedfs-db-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: seaweedfs-db-barman
          serverName: seaweedfs-db
YAMLEND
log "restore PVC drill-volume and recovery cluster drill-db created; waiting"
for i in $(seq 1 180); do
  rdy=$(kubectl -n "${NS}" get cluster.postgresql.cnpg.io drill-db -o jsonpath='{.status.readyInstances}' 2>/dev/null)
  [ "${rdy}" = "1" ] && { log "drill-db healthy"; break; }
  [ $((i % 6)) = 0 ] && log "  drill-db: $(kubectl -n "${NS}" get cluster.postgresql.cnpg.io drill-db -o jsonpath='{.status.phase}' 2>/dev/null)"
  sleep 10
done
[ "${rdy}" = "1" ] || { log "ABORT: drill-db never became ready"; exit 1; }
for i in $(seq 1 240); do ph=$(kubectl -n "${NS}" get pvc drill-volume -o jsonpath='{.status.phase}'); [ "${ph}" = "Bound" ] && break; sleep 10; done
[ "${ph}" = "Bound" ] || { log "ABORT: restored volume never bound"; exit 1; }
kubectl -n "${NS}" get secret drill-db-app >/dev/null 2>&1 || { log "ABORT: drill-db-app secret missing"; exit 1; }

# 4. scratch stack
kubectl apply -f "${DRILL_DIR}/stack.yaml" >/dev/null && log "scratch stack applied"
for d in drill-master drill-volume drill-filer; do
  kubectl -n "${NS}" rollout status "deployment/${d}" --timeout=600s >/dev/null 2>&1 && log "${d} ready" \
    || { log "${d} NOT ready"; kubectl -n "${NS}" logs "deployment/${d}" --tail=15 2>&1 | cut -c1-240; exit 1; }
done
log "RESTORE DONE: run verify.sh, then teardown.sh"
