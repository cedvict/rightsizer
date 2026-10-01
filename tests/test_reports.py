import csv
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
    assert sys.stdin.read() == ''  # Must not consume the namespace list.
    ns = sys.argv[sys.argv.index('-n') + 1]
    if ns == 'denied':
        print('Forbidden: permission refusée', file=sys.stderr)
        sys.exit(1)
    if ns == 'empty':
        print('{"items": []}')
    else:
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
                   MANIFEST_FILE='rightsizer-claims.json', ERROR_REPORT_FILE='rightsizer-errors.log',
                   QUOTA_JSON=json.dumps(self.quota),
                   APPLIED_FILE=str(self.root / 'applied.json'))
        env.update(overrides)
        return subprocess.run(['bash', str(SCRIPT), str(self.namespaces)],
                              cwd=self.output, env=env, text=True, capture_output=True)

    def assert_reports(self, result, count=1, code=0):
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
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

    def test_evaluation_failure_retains_reports_and_prevents_application(self):
        del self.quota['items'][0]['status']['used']['memory']
        result = self.run_script('false')
        self.assertNotEqual(result.returncode, 0)
        self.assert_reports(result, count=0, code=2)
        self.assertIn('incomplet', (self.output / 'rightsizer-errors.log').read_text())
        self.assertFalse((self.root / 'applied.json').exists())

    def test_mixed_permissions_dry_run_exports_accessible_namespaces(self):
        self.namespaces.write_text('denied\nempty\nexample\nexample')
        self.assert_reports(self.run_script(), code=2)
        self.assertIn('Forbidden', (self.output / 'rightsizer-errors.log').read_text())
        self.assertFalse((self.root / 'applied.json').exists())

    def test_mixed_permissions_block_application_but_retain_reports(self):
        self.namespaces.write_text('example\ndenied\n')
        self.assert_reports(self.run_script('false'), code=2)
        self.assertFalse((self.root / 'applied.json').exists())

    def test_all_denied_produces_empty_reports(self):
        self.namespaces.write_text('denied')
        self.assert_reports(self.run_script(), count=0, code=2)

    def test_invalid_quantity_is_reported_instead_of_coerced_to_zero(self):
        self.quota['items'][0]['status']['used']['memory'] = 'abcGi'
        self.assert_reports(self.run_script(), count=0, code=2)
        self.assertIn('abcGi', (self.output / 'rightsizer-errors.log').read_text())

    def test_invalid_structure_is_reported(self):
        self.quota['items'][0]['spec']['hard'] = None
        self.assert_reports(self.run_script(), count=0, code=2)

    def test_raw_bytes_and_fractional_memory_are_supported(self):
        self.quota['items'][0]['status']['used']['memory'] = '1572864'
        self.quota['items'][0]['spec']['hard']['memory'] = '2.5Mi'
        plan = self.assert_reports(self.run_script())
        self.assertEqual(plan['items'][0]['spec']['memory'], '2Mi')

    def test_sub_mi_quota_is_never_increased(self):
        self.quota['items'][0]['status']['used']['memory'] = '1Ki'
        self.quota['items'][0]['spec']['hard']['memory'] = '512Ki'
        plan = self.assert_reports(self.run_script())
        self.assertEqual(plan['items'][0]['spec']['memory'], '512Ki')

    def test_zero_quota_is_not_increased(self):
        self.quota['items'][0]['status']['used'] = {'cpu': '0', 'memory': '0'}
        self.quota['items'][0]['spec']['hard'] = {'cpu': '0', 'memory': '0'}
        self.assert_reports(self.run_script(), count=0)

    def test_invalid_configuration_does_not_contact_cluster(self):
        for overrides in [{'DRY_RUN': 'yes'}, {'MARGIN_PERCENT': '-5'},
                          {'MANIFEST_FILE': 'rightsizer-changes.tsv'}]:
            result = self.run_script('false', **overrides)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertFalse((self.root / 'applied.json').exists())

    def test_custom_output_directories_are_created(self):
        result = self.run_script(DRY_RUN_FILE='nested/report.tsv',
                                 MANIFEST_FILE='nested/claims.json',
                                 ERROR_REPORT_FILE='nested/errors.log')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.output / 'nested/report.tsv').exists())
        self.assertTrue((self.output / 'nested/claims.json').exists())
        self.assertEqual((self.output / 'nested/errors.log').read_text(), '')

    def test_requests_keys_are_selected_consistently(self):
        quota = self.quota['items'][0]
        quota['spec']['hard'] = {'requests.cpu': '2', 'requests.memory': '2Gi',
                                'cpu': '0', 'memory': '0'}
        quota['status']['used'] = {'requests.cpu': '0.5', 'requests.memory': '512Mi',
                                  'cpu': '0', 'memory': '0'}
        plan = self.assert_reports(self.run_script())
        self.assertEqual(plan['items'][0]['spec'], {'cpu': '525m', 'memory': '538Mi'})

    def test_malformed_json_is_reported(self):
        self.assert_reports(self.run_script(QUOTA_JSON='not JSON'), count=0, code=2)
        self.assertIn('JSON ResourceQuota invalide',
                      (self.output / 'rightsizer-errors.log').read_text())

    def test_success_clears_previous_error_report(self):
        self.namespaces.write_text('denied\n')
        self.assert_reports(self.run_script(), count=0, code=2)
        self.namespaces.write_text('example\n')
        self.assert_reports(self.run_script())
        self.assertEqual((self.output / 'rightsizer-errors.log').read_text(), '')

    def test_invalid_millicores_are_reported(self):
        self.quota['items'][0]['status']['used']['cpu'] = 'abcm'
        self.assert_reports(self.run_script(), count=0, code=2)

    def test_output_failure_blocks_application(self):
        (self.output / 'directory').mkdir()
        result = self.run_script('false', MANIFEST_FILE='directory')
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / 'applied.json').exists())

    def gain_rows(self):
        with (self.output / 'rightsizer-changes.tsv').open() as report:
            return list(csv.DictReader(report, delimiter='\t'))

    def test_gain_values_and_totals(self):
        self.namespaces.write_text('example\nsecond\n')
        result = self.run_script()
        self.assert_reports(result, count=2)
        row = self.gain_rows()[0]
        self.assertEqual(float(row['GAIN_CPU_M']), 950)
        self.assertEqual(float(row['GAIN_MEMORY_MI']), 972)
        self.assertEqual(row['GAIN_CPU_PERCENT'], '47.50')
        self.assertEqual(row['GAIN_MEMORY_PERCENT'], '47.46')
        self.assertIn('CPU : 1900 m (1.9 cores), 47.50%', result.stdout)
        self.assertIn('Mémoire : 1944 Mi (1.8984375 Gi), 47.46%', result.stdout)

    def test_gain_is_zero_for_unchanged_dimension(self):
        self.quota['items'][0]['status']['used']['memory'] = '2Gi'
        self.assert_reports(self.run_script())
        row = self.gain_rows()[0]
        self.assertEqual(row['GAIN_MEMORY_MI'], '0')
        self.assertEqual(row['GAIN_MEMORY_PERCENT'], '0.00')
        self.assertEqual(row['GAIN_CPU_M'], '950')

    def test_zero_baseline_produces_finite_zero_totals(self):
        self.quota['items'][0]['spec']['hard'] = {'cpu': '0', 'memory': '0'}
        self.quota['items'][0]['status']['used'] = {'cpu': '0', 'memory': '0'}
        result = self.run_script()
        self.assert_reports(result, count=0)
        self.assertIn('CPU : 0 m (0 cores), 0.00%', result.stdout)
        self.assertIn('Mémoire : 0 Mi (0 Gi), 0.00%', result.stdout)

    def test_partial_totals_include_only_evaluated_namespaces(self):
        self.namespaces.write_text('example\ndenied\nempty\n')
        result = self.run_script()
        self.assert_reports(result, code=2)
        self.assertIn('sur 1 namespace(s) évalué(s), 1 réduction(s)', result.stdout)
        self.assertIn('CPU : 950 m (0.95 cores), 47.50%', result.stdout)

    def test_fractional_memory_gain_uses_original_bytes(self):
        self.quota['items'][0]['spec']['hard']['memory'] = '2.5Mi'
        self.quota['items'][0]['status']['used']['memory'] = '1Mi'
        self.assert_reports(self.run_script())
        row = self.gain_rows()[0]
        self.assertEqual(float(row['GAIN_MEMORY_MI']), 0.5)
        self.assertEqual(row['GAIN_MEMORY_PERCENT'], '20.00')


if __name__ == '__main__':
    unittest.main()
