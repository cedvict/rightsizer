import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'resourcequota-rightsizer.sh'


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = self.root / 'output'
        self.output.mkdir()
        self.namespaces = self.root / 'namespaces.txt'
        self.namespaces.write_text('example\n')
        mock = self.root / 'kubectl'
        mock.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1] == 'get':
    assert sys.argv[2] == 'resourcequota'
    print(os.environ['QUOTA_JSON'])
else:
    assert sys.argv[1:3] == ['apply', '-f']
    pathlib.Path(os.environ['APPLIED_FILE']).write_text(pathlib.Path(sys.argv[3]).read_text())
''')
        mock.chmod(0o755)
        self.quota = {'items': [{'metadata': {'name': 'quota'},
                                'spec': {'hard': {'cpu': '2', 'memory': '2Gi'}},
                                'status': {'used': {'cpu': '1', 'memory': '1Gi'}}}]}

    def run_script(self, dry='true', **overrides):
        env = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'],
                   DRY_RUN=dry, DRY_RUN_FILE='rightsizer-changes.tsv',
                   MANIFEST_FILE='rightsizer-claims.json',
                   QUOTA_JSON=json.dumps(self.quota),
                   APPLIED_FILE=str(self.root / 'applied.json'))
        env.update(overrides)
        return subprocess.run(['bash', str(SCRIPT), str(self.namespaces)],
                              cwd=self.output, env=env, text=True, capture_output=True)

    def assert_reports(self, result, count=1):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = self.output / 'rightsizer-claims.json'
        report = self.output / 'rightsizer-changes.tsv'
        plan = json.loads(manifest.read_text())
        self.assertEqual(len(plan['items']), count)
        self.assertEqual(len(report.read_text().splitlines()), count + 1)
        self.assertIn(str(manifest), result.stdout)
        self.assertIn(str(report), result.stdout)
        return plan

    def test_dry_run_retains_reports_without_application(self):
        plan = self.assert_reports(self.run_script())
        self.assertEqual(plan['items'][0]['spec'], {'cpu': '1050m', 'memory': '1076Mi'})
        self.assertFalse((self.root / 'applied.json').exists())

    def test_application_retains_the_applied_plan(self):
        plan = self.assert_reports(self.run_script('false'))
        self.assertEqual(json.loads((self.root / 'applied.json').read_text()), plan)

    def test_empty_quota_still_produces_empty_reports(self):
        self.quota = {'items': []}
        self.assert_reports(self.run_script(), count=0)

    def test_no_reduction_still_produces_empty_reports(self):
        self.quota['items'][0]['status']['used'] = {'cpu': '2', 'memory': '2Gi'}
        self.assert_reports(self.run_script('false'), count=0)
        self.assertFalse((self.root / 'applied.json').exists())

    def test_evaluation_failure_prevents_reports_and_application(self):
        del self.quota['items'][0]['status']['used']['memory']
        result = self.run_script('false')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.output / 'rightsizer-claims.json').exists())
        self.assertFalse((self.output / 'rightsizer-changes.tsv').exists())
        self.assertFalse((self.root / 'applied.json').exists())


if __name__ == '__main__':
    unittest.main()
