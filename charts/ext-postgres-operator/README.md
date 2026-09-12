# ext-postgres-operator Helm Chart

This Helm chart deploys the External Postgres Operator, which provides a way to manage PostgreSQL databases and users in a Kubernetes environment.

## Installation

To install the chart, add the repository and use the `helm upgrade --install` command:

```bash
helm repo add ext-postgres-operator https://movetokube.github.io/postgres-operator/
helm upgrade --install -n operators ext-postgres-operator ext-postgres-operator/ext-postgres-operator
```

## CRD upgrades

From chart version `3.2.0`, the bundled `crds` subchart renders `Postgres` and
`PostgresUser` CRDs from `templates/`. They are included in the same Helm release
and updated by `helm upgrade`; no separate chart installation is needed.

`crds.enabled` defaults to `true`. CRDs are cluster-wide: only one release should
manage them. Set `crds.enabled=false` on additional operator releases, or when
CRDs are managed externally. `--skip-crds` does not skip these templated CRDs.

Both CRDs carry `helm.sh/resource-policy: keep`, so Helm retains them and their
custom resources on uninstall or when CRD management is disabled. Retained CRDs
are no longer updated by that release. When using Argo CD, configure its deletion
and pruning protection as well; do not rely solely on Helm's retention annotation.

### Existing Helm installations: one-time adoption

Before upgrading from the old `crds/` layout, assign the existing CRDs to the
operator's **current release name and namespace**. Set `KUBE_CONTEXT`,
`RELEASE_NAME` and `RELEASE_NAMESPACE` to your actual deployment values. First
inspect their metadata and confirm they are not managed by another release or
deployment tool:

```bash
kubectl --context "$KUBE_CONTEXT" get crd postgres.db.movetokube.com postgresusers.db.movetokube.com -o yaml
```

After confirming ownership, adopt only the two existing CRDs (this does not
recreate them or the custom resources):

```bash
: "${KUBE_CONTEXT:?Set the target Kubernetes context}"
: "${RELEASE_NAME:?Set the existing operator Helm release name}"
: "${RELEASE_NAMESPACE:?Set the existing operator Helm release namespace}"
kubectl --context "$KUBE_CONTEXT" label crd postgres.db.movetokube.com postgresusers.db.movetokube.com app.kubernetes.io/managed-by=Helm --overwrite
kubectl --context "$KUBE_CONTEXT" annotate crd postgres.db.movetokube.com postgresusers.db.movetokube.com "meta.helm.sh/release-name=$RELEASE_NAME" "meta.helm.sh/release-namespace=$RELEASE_NAMESPACE" helm.sh/resource-policy=keep --overwrite
```

Then upgrade the existing release using its normal values. Future upgrades update
the CRDs automatically. Fresh installations need no adoption step. Apply custom
resources using new fields only after the CRD upgrade has completed. Do not bundle
new `Postgres`/`PostgresUser` resources into the operator's first Helm installation:
Kubernetes must register the templated CRDs before Helm can validate those resources.

CRD schema changes require compatibility review, including when rolling back to
an older chart with older schemas. `keep` prevents deletion; it does not prevent
schema updates or downgrades.

## Validation

From the repository root:

```bash
helm lint charts/ext-postgres-operator --with-subcharts
python3 hack/test-helm-crds.py
bash hack/test-helm-crds-lifecycle.sh
```

The Python checks require PyYAML. The lifecycle test requires Docker, kind, Helm
and kubectl; it creates and removes its own local cluster with an isolated
kubeconfig and never starts the operator. CI runs both tests with Helm 3 and 4.

## Compatibility

**NOTE:** Helm chart version `>= 3.0.0` requires External Secret Operator version `>= 0.17.0`. Ensure that you are using the correct versions to avoid compatibility issues.

**NOTE:** Helm chart version `>= 2.0.0` is only compatible with the Postgres Operator version `2.0.0`. Ensure that you are using the correct versions to avoid compatibility issues.
