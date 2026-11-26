#!/usr/bin/env python3
"""Generate SYNTHETIC quarantine packages for the Quarantine Review Assistant tests.

Everything here is made up:
  * names use RFC 2606 / RFC 6761 domains (example.com, sender.example, *.invalid) and RFC 5737 documentation IPs;
  * "executables" are a handful of bytes that start with 'MZ' and do nothing;
  * there is no EICAR string and no real malware or real mail.

The outer ZIP is protected the way Microsoft Defender protects "Download message" packages (ZipCrypto), and also
with AES-256 for a few cases (needs the dev-only package `pyzipper`).

Usage:  python tests/make_samples.py [--out tests/.samples]
"""
from __future__ import annotations

import argparse
import base64
import json
import random
import struct
import zlib
from email.message import EmailMessage
from email.utils import format_datetime
from datetime import datetime, timezone
from pathlib import Path

OUTER_PASSWORD = 'Sample-Pass-123'
WRONG_PASSWORD = 'not-the-password'
FIXED_DATE = datetime(2026, 1, 5, 9, 0, 0, tzinfo=timezone.utc)
FAKE_EXE = b'MZ' + b'\x90\x00' + b'SYNTHETIC-TEST-FILE-DOES-NOTHING'   # a few bytes, not a runnable program
FAKE_JS = b'// synthetic test file - does nothing\r\n'
TEST_IBAN = 'GB82 WEST 1234 5698 7654 32'                              # the public IBAN-registry example, checksum valid


# ----------------------------------------------------------------------------- ZipCrypto writer (stdlib only)
def _crc_table() -> list[int]:
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
        table.append(c)
    return table


_T = _crc_table()


class _ZipCryptoKeys:
    def __init__(self, password: bytes):
        self.k = [0x12345678, 0x23456789, 0x34567890]
        for b in password:
            self.update(b)

    def update(self, c: int) -> None:
        k = self.k
        k[0] = (_T[(k[0] ^ c) & 0xFF] ^ (k[0] >> 8)) & 0xFFFFFFFF
        k[1] = ((k[1] + (k[0] & 0xFF)) * 134775813 + 1) & 0xFFFFFFFF
        k[2] = (_T[(k[2] ^ (k[1] >> 24)) & 0xFF] ^ (k[2] >> 8)) & 0xFFFFFFFF

    def stream_byte(self) -> int:
        t = (self.k[2] | 2) & 0xFFFF
        return ((t * (t ^ 1)) >> 8) & 0xFF


def zipcrypto_zip(entries: list[tuple[str, bytes]], password: str, seed: int = 1) -> bytes:
    """A ZIP whose entries use the traditional PKWARE (ZipCrypto) encryption, which is what Defender uses."""
    rng = random.Random(seed)
    dos_date = ((2026 - 1980) << 9) | (1 << 5) | 5
    dos_time = 9 << 11
    out = bytearray()
    central = bytearray()
    for name, data in entries:
        raw = name.encode('ascii')
        crc = zlib.crc32(data) & 0xFFFFFFFF
        comp = zlib.compressobj(6, zlib.DEFLATED, -15)
        body = comp.compress(data) + comp.flush()
        keys = _ZipCryptoKeys(password.encode('utf-8'))
        header = bytes(rng.getrandbits(8) for _ in range(11)) + bytes([crc >> 24])
        enc = bytearray()
        for c in header + body:
            enc.append(c ^ keys.stream_byte())
            keys.update(c)
        offset = len(out)
        out += struct.pack('<IHHHHHIIIHH', 0x04034B50, 20, 0x0001, 8, dos_time, dos_date, crc, len(enc), len(data), len(raw), 0)
        out += raw + enc
        central += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014B50, 20, 20, 0x0001, 8, dos_time, dos_date, crc, len(enc), len(data),
                               len(raw), 0, 0, 0, 0, 0, offset)
        central += raw
    cd_offset = len(out)
    out += central
    out += struct.pack('<IHHHHIIH', 0x06054B50, 0, 0, len(entries), len(entries), len(central), cd_offset, 0)
    return bytes(out)


def aes_zip(entries: list[tuple[str, bytes]], password: str) -> bytes:
    import io
    import pyzipper   # dev-only dependency
    buf = io.BytesIO()
    with pyzipper.AESZipFile(buf, 'w', compression=pyzipper.ZIP_DEFLATED, encryption=pyzipper.WZ_AES) as zf:
        zf.setpassword(password.encode('utf-8'))
        zf.setencryption(pyzipper.WZ_AES, nbits=256)
        for name, data in entries:
            zf.writestr(name, data)
    return buf.getvalue()


# ----------------------------------------------------------------------------- message builder
def auth_headers(ok: bool | str = True) -> dict[str, str]:
    if ok == 'blocked-type':
        # Microsoft blocked the attachment type (CAT:FTBP) and composite authentication failed; SPF, DKIM and DMARC are not reported.
        ar = 'mx.recipient.example; compauth=fail reason=001'
        ff = 'CIP:198.51.100.20;CTRY:US;LANG:en;SCL:9;SRV:;IPV:NLI;SFV:SPM;H:mail.sender.example;PTR:mail.sender.example;CAT:FTBP;DIR:INB'
    elif ok:
        ar = ('mx.recipient.example; spf=pass (sender IP is 198.51.100.20) smtp.mailfrom=sender.example; '
              'dkim=pass (signature was verified) header.d=sender.example; '
              'dmarc=pass action=none header.from=sender.example; compauth=pass reason=100')
        ff = 'CIP:198.51.100.20;CTRY:US;LANG:en;SCL:1;SRV:;IPV:NLI;SFV:NSPM;H:mail.sender.example;PTR:mail.sender.example;CAT:NONE;DIR:INB'
    else:
        ar = ('mx.recipient.example; spf=fail (sender IP is 198.51.100.20) smtp.mailfrom=sender.example; dkim=none (message not signed); '
              'dmarc=fail action=none header.from=sender.example; compauth=fail reason=001')
        ff = 'CIP:198.51.100.20;CTRY:US;LANG:en;SCL:1;SRV:;IPV:NLI;SFV:NSPM;H:mail.hosting.example;PTR:mail.hosting.example;CAT:NONE;DIR:INB'
    return {'Authentication-Results': ar, 'X-Forefront-Antispam-Report': ff}


def build_eml(subject: str, text: str, html: str | None = None, attachments: list[tuple[str, str, str, bytes]] | None = None,
              auth_ok: bool | str = True, sender_name: str = 'Alice Example', index: int = 1) -> bytes:
    msg = EmailMessage()
    msg['From'] = f'{sender_name} <alice@sender.example>'
    msg['To'] = 'Bob Example <bob@recipient.example>'
    msg['Subject'] = subject
    msg['Date'] = format_datetime(FIXED_DATE)
    msg['Message-ID'] = f'<synthetic-{index}@sender.example>'
    msg['Return-Path'] = '<alice@sender.example>'
    msg['Received'] = ('from mail.sender.example ([198.51.100.20]) by mx.recipient.example with ESMTPS; ' + format_datetime(FIXED_DATE))
    for k, v in auth_headers(auth_ok).items():
        msg[k] = v
    msg.set_content(text)
    if html:
        msg.add_alternative(html, subtype='html')
    for filename, maintype, subtype, data in attachments or []:
        msg.add_attachment(data, maintype=maintype, subtype=subtype, filename=filename)
    return msg.as_bytes()


# ----------------------------------------------------------------------------- the cases
def case_benign() -> bytes:
    return build_eml('Meeting moved to Thursday',
                     'Hi Bob,\n\nThe team meeting moved to 3pm on Thursday. Same room as usual.\n\nThanks,\nAlice\n', index=1)


def tiny_png(n: int) -> bytes:
    """A valid 1x1 PNG (a few dozen bytes). The colour depends on n so the six files differ."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(bytes([0, 40 * n % 256, 80, 160]))) + chunk(b'IEND', b''))


def case_exe_in_zip() -> bytes:
    """Same structure as the public demo: six images and a ZIP that holds an executable, a link whose text shows another domain,
    a second plain link, composite authentication failed, and Microsoft blocking the attachment type."""
    inner = zipcrypto_free_zip([('Schedule-demo.exe', FAKE_EXE)])
    images = [(f'demo-image-{n}.png', 'image', 'png', tiny_png(n)) for n in range(1, 7)]
    html = ('<html><body><p>Hi Bob,</p><p>This week\'s schedule is attached. Details: '
            '<a href="https://destination.invalid/demo">display.invalid</a></p></body></html>')
    return build_eml('Synthetic demo - weekly schedule',
                     'Hi Bob,\n\nThis week\'s schedule is attached. Details: https://display.invalid/demo\n',
                     html=html, attachments=images + [('Weekly-schedule.zip', 'application', 'zip', inner)],
                     auth_ok='blocked-type', index=2)


def case_html_smuggling() -> bytes:
    payload = base64.b64encode(b'SYNTHETIC').decode()
    page = ('<html><body><p>Loading your document...</p><script>\n'
            f'var d = atob("{payload}");\n'
            'var b = new Blob([d], {type: "application/octet-stream"});\n'
            'var a = document.createElement("a"); a.href = URL.createObjectURL(b); a.download = "document.bin"; a.click();\n'
            '</script></body></html>').encode()
    return build_eml('Remittance advice', 'Hi Bob,\n\nRemittance advice attached.\n\nAlice\n',
                     attachments=[('Remittance-advice.html', 'text', 'html', page)], index=3)


def case_bec_payment() -> bytes:
    body = ('Hello Bob,\n\nOur bank details have changed with immediate effect. Please remit to our new account:\n'
            f'IBAN {TEST_IBAN}\n\nThis is urgent: please confirm once the transfer is done. '
            'Please keep this confidential until our audit is finished.\n\nAlice\n')
    return build_eml('Updated payment instructions', body, index=4)


def case_auth_fail_only() -> bytes:
    return build_eml('Quarterly newsletter draft',
                     'Hi Bob,\n\nHere is the draft text for the quarterly newsletter. No action needed.\n\nAlice\n',
                     auth_ok=False, index=5)


def case_deceptive_link() -> bytes:
    html = ('<html><body><p>Hi Bob,</p><p>Please review the updated policy: '
            '<a href="http://secure-login.deceptive.invalid/policy">https://www.sender.example/policy</a></p></body></html>')
    return build_eml('Updated policy', 'Hi Bob,\n\nPlease review the updated policy at https://www.sender.example/policy\n\nAlice\n',
                     html=html, index=6)


INNER_PASSWORD = 'Spring2026'


def case_password_inner_zip() -> bytes:
    inner = zipcrypto_zip([('Statement.js', FAKE_JS)], INNER_PASSWORD, seed=7)
    body = f'Hi Bob,\n\nThe statement is in the attached archive. The archive password is: {INNER_PASSWORD}\n\nAlice\n'
    return build_eml('Account statement', body, attachments=[('Statements.zip', 'application', 'zip', inner)], index=7)


def zipcrypto_free_zip(entries: list[tuple[str, bytes]]) -> bytes:
    """An ordinary (unencrypted) ZIP, as an attacker would attach."""
    import io
    import zipfile
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries:
            zi = zipfile.ZipInfo(name, (2026, 1, 5, 9, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(zi, data)
    return buf.getvalue()


# name -> (builder, outer encryption, password the *tool* is given)
CASES: dict[str, tuple] = {
    'benign_plain':          (case_benign,             'zipcrypto', OUTER_PASSWORD),
    'benign_plain_aes':      (case_benign,             'aes',       OUTER_PASSWORD),
    'exe_in_zip':            (case_exe_in_zip,         'zipcrypto', OUTER_PASSWORD),
    'exe_in_zip_aes':        (case_exe_in_zip,         'aes',       OUTER_PASSWORD),
    'html_smuggling':        (case_html_smuggling,     'zipcrypto', OUTER_PASSWORD),
    'bec_payment':           (case_bec_payment,        'zipcrypto', OUTER_PASSWORD),
    'auth_fail_only':        (case_auth_fail_only,     'zipcrypto', OUTER_PASSWORD),
    'deceptive_link':        (case_deceptive_link,     'zipcrypto', OUTER_PASSWORD),
    'password_inner_zip':    (case_password_inner_zip, 'zipcrypto', OUTER_PASSWORD),
    'wrong_outer_password':  (case_exe_in_zip,         'zipcrypto', WRONG_PASSWORD),
}


def package(eml: bytes, outer: str) -> bytes:
    entries = [('00000000-0000-4000-8000-000000000001.eml', eml)]   # synthetic id, Defender names entries by message id
    return aes_zip(entries, OUTER_PASSWORD) if outer == 'aes' else zipcrypto_zip(entries, OUTER_PASSWORD)


def build_all(out_dir: Path) -> dict[str, dict]:
    """Write every sample into out_dir and return {case: {'path': ..., 'password': ...}}."""
    out_dir.mkdir(parents=True, exist_ok=True)
    result = {}
    for name, (builder, outer, tool_password) in CASES.items():
        path = out_dir / f'{name}.zip'
        path.write_bytes(package(builder(), outer))
        result[name] = {'path': path, 'password': tool_password, 'outer': outer}
    return result


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--out', default=str(Path(__file__).parent / '.samples'))
    args = ap.parse_args()
    made = build_all(Path(args.out))
    print(json.dumps({k: {**v, 'path': str(v['path'])} for k, v in made.items()}, indent=2))
