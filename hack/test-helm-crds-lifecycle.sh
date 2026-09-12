#!/usr/bin/env bash
# Creates and removes its own kind cluster; never uses the caller's kubeconfig.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
cluster="operator-crds-$$"
export KUBECONFIG="$work/kubeconfig"
cleanup() {
  kind delete cluster --name "$cluster" --kubeconfig "$KUBECONFIG"
  rm -rf "$work"
}
trap cleanup EXIT
kind create cluster --name "$cluster" --kubeconfig "$KUBECONFIG" --wait 120s

# Some local Docker runtimes advertise a wildcard host address. Connect through
# loopback, which is included in kind's API-server certificate.
python3 - "$KUBECONFIG" <<'PYCONFIG'
from pathlib import Path
import sys
import yaml
path = Path(sys.argv[1])
config = yaml.safe_load(path.read_text())
for cluster in config['clusters']:
    server = cluster['cluster']['server']
    cluster['cluster']['server'] = server.replace('https://0.0.0.0:', 'https://127.0.0.1:')
path.write_text(yaml.safe_dump(config))
PYCONFIG

chart="$root/charts/ext-postgres-operator"
release=crd-test
namespace=operator-test
resources=(postgres.db.movetokube.com postgresusers.db.movetokube.com)

# Reproduce a legacy release: install-only CRDs, without the new repair fields.
python3 - "$root" "$work" <<'PY'
from pathlib import Path
import sys
import yaml
root, work = map(Path, sys.argv[1:])
legacy = work / 'legacy'
(legacy / 'crds').mkdir(parents=True)
(legacy / 'Chart.yaml').write_text('apiVersion: v2\nname: legacy\nversion: 1.0.0\n')
for source in (root / 'config/crd/bases').glob('*.yaml'):
    crd = yaml.safe_load(source.read_text())
    for version in crd['spec']['versions']:
        props = version['schema']['openAPIV3Schema']['properties']
        for field in ('spec', 'status'):
            props[field]['properties'].pop('permissionRepair', None)
    (legacy / 'crds' / source.name).write_text(yaml.safe_dump(crd))
PY
helm install "$release" "$work/legacy" --namespace "$namespace" --create-namespace
kubectl wait --for=condition=Established --timeout=60s crd "${resources[@]}"
kubectl -n "$namespace" apply -f "$root/config/samples/db_v1alpha1_postgres.yaml" -f "$root/config/samples/db_v1alpha1_postgresuser.yaml"
uids() {
  kubectl -n "$namespace" get postgres/my-db postgresuser/my-db-user -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}'
  kubectl get crd "${resources[@]}" -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}'
}
before=$(uids)
# Follow the documented adoption path. No controller runs or connects to PostgreSQL.
kubectl label crd "${resources[@]}" app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate crd "${resources[@]}" "meta.helm.sh/release-name=$release" "meta.helm.sh/release-namespace=$namespace" helm.sh/resource-policy=keep --overwrite
helm upgrade "$release" "$chart" --namespace "$namespace" --set replicaCount=0
kubectl -n "$namespace" patch postgres my-db --type=merge -p '{"spec":{"permissionRepair":{"schedule":"0 2 * * *"}}}'
test "$(kubectl -n "$namespace" get postgres my-db -o jsonpath='{.spec.permissionRepair.schedule}')" = '0 2 * * *'
test "$(uids)" = "$before"

# Disabling management and uninstalling must preserve both CRDs and existing CRs.
helm upgrade "$release" "$chart" --namespace "$namespace" --set replicaCount=0 --set crds.enabled=false
test "$(uids)" = "$before"
helm upgrade "$release" "$chart" --namespace "$namespace" --set replicaCount=0
helm uninstall "$release" --namespace "$namespace"
test "$(uids)" = "$before"

# A fresh chart install also works with no CRDs already registered.
kubectl delete crd "${resources[@]}" --wait=true
helm install "$release" "$chart" --namespace "$namespace" --set replicaCount=0
kubectl wait --for=condition=Established --timeout=60s crd "${resources[@]}"
kubectl -n "$namespace" apply -f "$root/config/samples/db_v1alpha1_postgres.yaml" -f "$root/config/samples/db_v1alpha1_postgresuser.yaml"
before=$(uids)
helm uninstall "$release" --namespace "$namespace"
test "$(uids)" = "$before"
echo 'CRD adoption, schema upgrade, fresh install, and retention passed.'
