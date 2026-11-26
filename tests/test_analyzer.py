"""Run the analyzer exactly as the GUI does (through its CLI) and compare the result with tests/expected/*.json."""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import sys
from email.message import EmailMessage
from pathlib import Path

import pytest

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
ANALYZER = ROOT / 'src' / 'SecurityReview' / 'app' / 'inspect_eml.py'
SAMPLES = TESTS / '.samples'
EXPECTED = TESTS / 'expected'
SEV = {'info': 0, 'low': 1, 'medium': 2, 'high': 3}

sys.path.insert(0, str(TESTS))
import make_samples  # noqa: E402


@pytest.fixture(scope='session')
def samples() -> dict:
    return make_samples.build_all(SAMPLES)


def run_cli(package: Path, stdin: str, out_json: Path, *extra: str) -> subprocess.CompletedProcess:
    cmd = [sys.executable, '-I', '-B', '-X', 'utf8', str(ANALYZER), '--input', str(package), '--json-out', str(out_json), *extra]
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=120)


def analyze(sample: dict, tmp_path: Path) -> tuple[subprocess.CompletedProcess, dict]:
    out = tmp_path / 'report.json'
    proc = run_cli(sample['path'], sample['password'] + '\n', out, '--password-stdin')
    assert out.is_file(), f'no JSON report written; stderr:\n{proc.stderr}'
    return proc, json.loads(out.read_text(encoding='utf-8'))


def walk(node: dict):
    yield node
    for child in node.get('children') or []:
        yield from walk(child)


CASES = sorted(p.stem for p in EXPECTED.glob('*.json'))


def test_every_sample_has_an_expectation():
    assert set(CASES) == set(make_samples.CASES), 'tests/expected and make_samples.CASES are out of sync'


@pytest.mark.parametrize('case', CASES)
def test_case(case: str, samples: dict, tmp_path: Path):
    exp = json.loads((EXPECTED / f'{case}.json').read_text(encoding='utf-8'))
    sample = samples[case]
    if sample['outer'] == 'aes':
        pytest.importorskip('pyzipper')
    proc, rep = analyze(sample, tmp_path)

    assert proc.returncode == exp['exit_code'], proc.stderr
    assert rep['assessment']['level'] == exp['assessment_level']

    for key, want in exp.get('decision', {}).items():
        assert rep['decision'][key] == want, f'decision.{key}'
    for key, want in exp.get('container', {}).items():
        assert rep['container'].get(key) == want, f'container.{key}'

    msgs = rep['messages']
    if 'messages' in exp:
        assert len(msgs) == exp['messages']
    top = msgs[0] if msgs else {}

    findings = rep['findings']
    for want in exp.get('findings', []):
        hits = [f for f in findings if f['code'] == want['code'] and f['where'] == want['where']]
        assert hits, f"missing finding {want['code']} at {want['where']!r}; have: " + ', '.join(f"{f['code']}@{f['where']}" for f in findings)
        assert hits[0]['severity'] == want['severity'], f"{want['code']} severity"
    for code in exp.get('absent_codes', []):
        assert code not in {f['code'] for f in findings}, f'unexpected finding {code}'
    if 'max_severity' in exp:
        worst = max((SEV[f['severity']] for f in findings), default=0)
        assert worst <= SEV[exp['max_severity']], 'a finding is more severe than expected'

    if 'attachment_count' in exp:
        assert top.get('attachment_count') == exp['attachment_count']
    if 'finding_count' in exp:
        assert len(findings) == exp['finding_count']
    if 'link_count' in exp:
        assert len(rep['urls']) == exp['link_count']
    if 'ibans' in exp:
        assert top.get('ibans') == exp['ibans']
    if 'password_hint_count' in exp:
        assert top.get('password_hint_count') == exp['password_hint_count']
    if 'unlocked' in exp:
        assert rep['unlocked'] == exp['unlocked']
    for want in exp.get('tree', []):
        node = top
        for name in want['path']:
            node = next((c for c in node['children'] if c['name'] == name), None)
            assert node is not None, f"attachment path {' > '.join(want['path'])} not found"
    for want in exp.get('urls', []):
        hits = [u for u in rep['urls'] if want['defanged_contains'] in u['defanged']]
        assert hits, f"no URL containing {want['defanged_contains']!r}"
        assert hits[0]['severity'] == want['severity']
        assert want['flag_contains'] == '' and not hits[0]['flags'] or any(want['flag_contains'] in fl for fl in hits[0]['flags']), hits[0]['flags']
    for sid, status in exp.get('scorecard', {}).items():
        got = {s['id']: s['status'] for s in rep['decision']['scorecard']}
        assert got[sid] == status, f'scorecard {sid}'
    if 'iocs_sha256_count' in exp:
        assert len(rep['decision']['iocs']['sha256']) == exp['iocs_sha256_count']
    if 'iocs_domains' in exp:
        assert rep['decision']['iocs']['domains'] == exp['iocs_domains']
    for text in exp.get('errors_contain', []):
        assert any(text in e for e in rep['errors']), rep['errors']


def test_secrets_stdin_matches_password_stdin(samples: dict, tmp_path: Path):
    """The GUI sends one JSON line (--secrets-stdin); the result must equal the --password-stdin run."""
    s = samples['exe_in_zip']
    out1, out2 = tmp_path / 'a.json', tmp_path / 'b.json'
    run_cli(s['path'], s['password'] + '\n', out1, '--password-stdin')
    run_cli(s['path'], json.dumps({'zip_password': s['password'], 'attachment_passwords': []}) + '\n', out2, '--secrets-stdin')
    a, b = json.loads(out1.read_text()), json.loads(out2.read_text())
    for r in (a, b):
        r.pop('generated_utc')
    assert a == b


def test_password_is_not_in_the_reports(samples: dict, tmp_path: Path):
    s = samples['benign_plain']
    out, txt = tmp_path / 'r.json', tmp_path / 'r.txt'
    run_cli(s['path'], s['password'] + '\n', out, '--password-stdin', '--text-out', str(txt))
    assert s['password'] not in out.read_text() and s['password'] not in txt.read_text()


def test_report_version_matches_the_release_version(samples: dict, tmp_path: Path):
    _, rep = analyze(samples['benign_plain'], tmp_path)
    readme = (ROOT / 'src' / 'SecurityReview' / 'README.md').read_text(encoding='utf-8')
    assert re.search(r'^# Quarantine Review Assistant v' + re.escape(rep['version']) + r'\b', readme, re.M)


@pytest.mark.parametrize('supplied', [False, True])
def test_inner_password_only_reports_its_source(tmp_path: Path, supplied: bool):
    password = 'Archive-Key-73'
    body = f'The password is {password}.' if not supplied else f'For reference, {password} was agreed yesterday.'
    inner = make_samples.zipcrypto_zip([('notes.txt', b'Meeting notes')], password)
    package = tmp_path / 'meeting.eml'
    package.write_bytes(make_samples.build_eml('Meeting', body, attachments=[('notes.zip', 'application', 'zip', inner)]))
    out, txt = tmp_path / 'report.json', tmp_path / 'report.txt'
    secrets = {'attachment_passwords': [password] if supplied else []}
    proc = run_cli(package, json.dumps(secrets), out, '--secrets-stdin', '--text-out', str(txt))
    assert proc.returncode == 0
    assert all(password not in s for s in (out.read_text(), txt.read_text(), proc.stdout, proc.stderr))
    result = json.loads(out.read_text())
    assert result['unlocked'][0]['source'] == ('operator' if supplied else 'message_body')


def assert_incomplete(proc, result):
    assert proc.returncode == 3
    assert result['complete'] is False
    assert result['assessment']['level'] == 'INCOMPLETE'
    assert result['decision']['outcome'] == 'RERUN'
    assert all(sc['status'] != 'green' for sc in result['decision']['scorecard'] if sc['id'] == 'files')


@pytest.mark.parametrize('case', ['locked', 'bad_zip', 'nested', 'locked_office', 'embedded_office'])
def test_uninspected_nested_content_holds_message(tmp_path: Path, case: str):
    name = 'notes.zip'
    if case == 'locked':
        inner = make_samples.zipcrypto_zip([('notes.txt', b'Notes')], 'Keys-Only-73')
    elif case == 'bad_zip':
        inner = b'PK\x03\x04'
    elif case == 'nested':
        inner = make_samples.zipcrypto_free_zip([('notes.txt', b'Notes')])
        for _ in range(5):
            inner = make_samples.zipcrypto_free_zip([('folder.zip', inner)])
    elif case == 'locked_office':
        name = 'notes.docx'
        inner = make_samples.zipcrypto_zip([('[Content_Types].xml', b'<Types/>')], 'Keys-Only-73')
    else:
        name = 'notes.docx'
        inner = make_samples.zipcrypto_free_zip([('[Content_Types].xml', b'<Types/>'),
                                                 ('word/embeddings/notes.bin', b'Embedded notes')])
    package = tmp_path / 'meeting.eml'
    package.write_bytes(make_samples.build_eml('Meeting', 'Agenda attached.',
                                               attachments=[(name, 'application', 'octet-stream', inner)]))
    proc, result = analyze({'path': package, 'password': ''}, tmp_path)
    assert_incomplete(proc, result)
    assert any(name in e for e in result['errors'])


def test_mixed_package_records_unreviewed_entry(tmp_path: Path):
    package = tmp_path / 'mixed.zip'
    package.write_bytes(make_samples.zipcrypto_free_zip([('mail.eml', make_samples.case_benign()), ('extra.txt', b'Notes')]))
    proc, result = analyze({'path': package, 'password': ''}, tmp_path)
    assert_incomplete(proc, result)
    assert any('extra.txt' in e for e in result['errors'])


def test_multiple_messages_require_individual_review(tmp_path: Path):
    package = tmp_path / 'messages.zip'
    package.write_bytes(make_samples.zipcrypto_free_zip([('one.eml', make_samples.case_auth_fail_only()),
                                                         ('two.eml', make_samples.case_benign())]))
    proc, result = analyze({'path': package, 'password': ''}, tmp_path)
    assert_incomplete(proc, result)
    assert result['container']['requires_individual_review']
    assert result['container']['messages'] == 2
    assert not result['messages']
    decision = result['decision']
    assert not any(decision['iocs'].values())
    assert not decision['spoof_pair']
    assert list(decision['steps']) == ['RERUN']
    assert 'separat' in ' '.join(decision['steps']['RERUN']).lower()


def test_secret_in_evidence_is_redacted_without_changing_hashes(tmp_path: Path):
    password = 'Room-Key-47'
    eml = make_samples.build_eml(f'Notes from {password}', f'Document: https://docs.invalid/{password}.zip',
                                 attachments=[(password + '.txt', 'text', 'plain', b'Meeting notes')])
    package = tmp_path / 'meeting.eml'
    package.write_bytes(eml)
    out = tmp_path / 'report.json'
    proc = run_cli(package, json.dumps({'attachment_passwords': [password]}), out, '--secrets-stdin')
    assert proc.returncode == 0
    assert password not in proc.stdout and password not in out.read_text()
    result = json.loads(out.read_text())
    assert result['input']['hashes']['sha256'] == hashlib.sha256(eml).hexdigest()
    assert result['messages'][0]['children'][0]['hashes']['sha256'] == hashlib.sha256(b'Meeting notes').hexdigest()
    assert result['decision']['iocs']['urls'] == []
    assert 'docs.invalid' in result['decision']['iocs']['domains']


def test_incomplete_mime_attachment_requires_review(tmp_path: Path):
    eml = make_samples.build_eml('Meeting', 'Notes attached.', attachments=[('notes.txt', 'text', 'plain', b'Notes')])
    package = tmp_path / 'meeting.eml'
    package.write_bytes(eml.replace(b'Tm90ZXM=', b'Tm90ZXM'))
    proc, result = analyze({'path': package, 'password': ''}, tmp_path)
    assert_incomplete(proc, result)
    assert any('notes.txt' in e for e in result['errors'])


@pytest.mark.parametrize('case', ['scan_limit', 'office_size', 'office_other'])
def test_skipped_attachment_parts_require_review(tmp_path: Path, monkeypatch, case: str):
    monkeypatch.syspath_prepend(str(ANALYZER.parent))
    import inspect_eml
    name, data = 'notes.txt', b'Standard meeting minutes.'
    if case == 'scan_limit':
        monkeypatch.setattr(inspect_eml, 'MAX_TEXT_SCAN', 16)
    elif case == 'office_size':
        data = make_samples.zipcrypto_free_zip([('[Content_Types].xml', b'<Types/>'),
                                                ('word/document.xml', b' ' * (4 * 1024 * 1024 + 1))])
        name = 'notes.docx'
    else:
        data = make_samples.zipcrypto_free_zip([('[Content_Types].xml', b'<Types/>'), ('extra.zip', b'Notes')])
        name = 'notes.docx'
    package = tmp_path / 'meeting.eml'
    package.write_bytes(make_samples.build_eml('Meeting', 'Notes.', attachments=[(name, 'application', 'octet-stream', data)]))
    result = inspect_eml.inspect_input(package, {}, inspect_eml.Progress(None))
    assert not result['complete'] and result['decision']['outcome'] == 'RERUN'
    assert any(name in e for e in result['errors'])


def test_inline_mime_parts_are_inspected(tmp_path: Path):
    msg = EmailMessage()
    msg['From'] = 'alice@sender.example'
    msg['To'] = 'bob@recipient.example'
    msg['Subject'] = 'Notes'
    msg.set_content('Meeting notes.')
    locked = make_samples.zipcrypto_zip([('notes.txt', b'Notes')], 'Keys-Only-73')
    msg.add_related(locked, maintype='image', subtype='png', cid='<notes>', disposition='inline')
    package = tmp_path / 'meeting.eml'
    package.write_bytes(msg.as_bytes())
    proc, result = analyze({'path': package, 'password': ''}, tmp_path)
    assert_incomplete(proc, result)
    assert any('notes.txt' in e for e in result['errors'])


def test_unreadable_office_xml_is_incomplete(tmp_path: Path):
    office = make_samples.zipcrypto_free_zip([('[Content_Types].xml', b'<Types/>'), ('word/document.xml', b'\xff')])
    package = tmp_path / 'meeting.eml'
    package.write_bytes(make_samples.build_eml('Meeting', 'Notes.', attachments=[('notes.docx', 'application', 'octet-stream', office)]))
    proc, result = analyze({'path': package, 'password': ''}, tmp_path)
    assert_incomplete(proc, result)
    assert any('word/document.xml' in e for e in result['errors'])
