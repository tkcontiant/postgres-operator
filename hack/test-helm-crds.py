#!/usr/bin/env python3
"""Check the shipped Helm CRDs without connecting to a Kubernetes cluster."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / 'charts/ext-postgres-operator'
RELEASE = 'crd-test'
NAMESPACE = 'operator-test'


def helm(*args):
    return subprocess.check_output(['helm', *map(str, args)], text=True)


def render(chart=CHART, *args):
    return [doc for doc in yaml.safe_load_all(helm(
        'template', RELEASE, chart, '--namespace', NAMESPACE, *args)) if doc]


def crds(documents):
    return [doc for doc in documents if doc['kind'] == 'CustomResourceDefinition']


def schema_without_descriptions(value):
    # Generated descriptions can differ in wrapping without changing validation.
    if isinstance(value, dict):
        return {k: schema_without_descriptions(v) for k, v in value.items()
                if k != 'description'}
    if isinstance(value, list):
        return [schema_without_descriptions(v) for v in value]
    return value


class HelmCRDsTest(unittest.TestCase):
    def assert_crds(self, documents):
        resources = crds(documents)
        expected = {yaml.safe_load(path.read_text())['metadata']['name']:
                    yaml.safe_load(path.read_text())
                    for path in (ROOT / 'config/crd/bases').glob('*.yaml')}
        self.assertEqual(len(resources), 2)
        self.assertEqual({r['metadata']['name'] for r in resources}, set(expected))
        for resource in resources:
            metadata = resource['metadata']
            self.assertNotIn('namespace', metadata)
            self.assertEqual(metadata['annotations']['helm.sh/resource-policy'], 'keep')
            self.assertNotIn('helm.sh/hook', metadata['annotations'])
            self.assertEqual(metadata['annotations']['meta.helm.sh/release-name'], RELEASE)
            self.assertEqual(metadata['annotations']['meta.helm.sh/release-namespace'], NAMESPACE)
            self.assertEqual(metadata['labels']['app.kubernetes.io/managed-by'], 'Helm')
            self.assertEqual(schema_without_descriptions(resource['spec']),
                             schema_without_descriptions(expected[metadata['name']]['spec']))

    def test_install_and_upgrade_include_current_crds_once(self):
        self.assert_crds(render())
        self.assert_crds(render(CHART, '--is-upgrade', '--include-crds'))
        self.assertFalse((CHART / 'crds').exists())

    def test_disabled_crds_preserve_other_resources(self):
        enabled = render()
        disabled = render(CHART, '--set', 'crds.enabled=false')
        self.assertEqual(crds(disabled), [])
        self.assertEqual(disabled, [d for d in enabled if d['kind'] != 'CustomResourceDefinition'])

    def test_packaged_chart_includes_subchart(self):
        with tempfile.TemporaryDirectory() as directory:
            helm('package', CHART, '--destination', directory)
            package, = Path(directory).glob('*.tgz')
            self.assert_crds(render(package))
            self.assert_crds(render(package, '--is-upgrade'))
            self.assertEqual(crds(render(package, '--set', 'crds.enabled=false')), [])


if __name__ == '__main__':
    unittest.main()
