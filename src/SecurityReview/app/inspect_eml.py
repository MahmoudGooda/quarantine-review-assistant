#!/usr/bin/env python3
"""Quarantine Review Assistant v2 - offline, metadata-only review of quarantined email.

Inputs : Microsoft Defender / EOP quarantine download ZIP, a raw .eml, or any ZIP.
Outputs: structured JSON (for the GUI) and a plain-text report.

Design rules
  * Standard library only (runs on the official Python embeddable package).
  * Nothing is executed, rendered, or written to disk except the report files.
  * Archives are decrypted / decompressed IN MEMORY with strict size budgets.
  * This is NOT a malware scanner. A report with no findings is NOT a "safe" verdict.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import bz2
import datetime as _dt
import hashlib
import hmac
import html
import io
import json
import lzma
import os
import re
import struct
import sys
import unicodedata
import zipfile
import zlib
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses, parseaddr
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

VERSION = '2.3.0'

# --------------------------------------------------------------------------- limits
MAX_SOURCE = 150 * 1024 * 1024          # input file on disk
MAX_EML = 100 * 1024 * 1024             # one message
MAX_ZIP_ITEMS = 1000
MAX_TOTAL_DECLARED = 400 * 1024 * 1024  # declared uncompressed size of one archive
MAX_ATTACHMENT = 80 * 1024 * 1024
MAX_READ_ENTRY = 40 * 1024 * 1024       # one archive entry decoded in memory
MAX_DECODED_TOTAL = 256 * 1024 * 1024   # whole run
MAX_DEPTH = 4                           # archive / message nesting
MAX_TEXT_SCAN = 6 * 1024 * 1024         # bytes of an HTML/text/PDF part scanned
MAX_URLS = 300
MAX_PASSWORD_CANDIDATES = 25

# --------------------------------------------------------------------------- vocab
EXEC_EXT = {'.exe', '.com', '.scr', '.pif', '.dll', '.cpl', '.sys', '.drv', '.ocx', '.efi'}
SCRIPT_EXT = {'.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.vbs', '.vbe', '.js', '.jse', '.wsf',
              '.wsh', '.wsc', '.hta', '.sct', '.reg', '.jar', '.class', '.py', '.pyw', '.sh',
              '.msh', '.inf', '.scf', '.xbap', '.application', '.gadget', '.ws', '.mjs'}
INSTALLER_EXT = {'.msi', '.msp', '.mst', '.msix', '.msixbundle', '.appx', '.appxbundle',
                 '.appinstaller', '.appref-ms', '.vsto', '.settingcontent-ms'}
DISK_EXT = {'.iso', '.img', '.vhd', '.vhdx', '.udf', '.dmg'}
SHORTCUT_EXT = {'.lnk', '.url', '.website', '.library-ms', '.search-ms', '.searchconnector-ms'}
MACRO_OFFICE_EXT = {'.docm', '.dotm', '.xlsm', '.xltm', '.xlam', '.xla', '.xll', '.xlsb',
                    '.pptm', '.potm', '.ppam', '.ppsm', '.sldm'}
OTHER_RISKY_EXT = {'.one', '.onepkg', '.iqy', '.slk', '.chm', '.hlp', '.mht', '.mhtml',
                   '.svgz', '.wbk', '.diagcab', '.cab', '.ace', '.arj'}
HTML_EXT = {'.htm', '.html', '.shtml', '.shtm', '.xhtml', '.xht', '.svg', '.hta'}
ARCHIVE_EXT = {'.zip', '.rar', '.7z', '.gz', '.tgz', '.bz2', '.xz', '.tar', '.cab', '.arj',
               '.ace', '.lzh', '.z', '.zipx', '.r00', '.uue', '.xxe'}
DECOY_EXT = {'.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.jpg', '.jpeg',
             '.png', '.gif', '.txt', '.csv', '.rtf', '.mp3', '.mp4', '.wav', '.html', '.htm'}
HIGH_RISK_EXT = EXEC_EXT | SCRIPT_EXT | INSTALLER_EXT | DISK_EXT | SHORTCUT_EXT | MACRO_OFFICE_EXT | {'.one', '.onepkg', '.chm', '.hlp', '.iqy', '.slk', '.hta'}

URL_SHORTENERS = {'bit.ly', 'tinyurl.com', 't.co', 'goo.gl', 'ow.ly', 'is.gd', 'buff.ly',
                  'cutt.ly', 'rebrand.ly', 'rb.gy', 'shorturl.at', 'tiny.cc', 's.id', 't.ly',
                  'lnkd.in', 'qrco.de', 'bl.ink', 'short.io', 'v.gd', 'urlz.fr'}
ABUSED_HOSTING = ('web.core.windows.net', 'blob.core.windows.net', 'azurewebsites.net',
                  'firebasestorage.googleapis.com', 'firebaseapp.com', 'web.app',
                  'storage.googleapis.com', 'appspot.com', 'r2.dev', 'pages.dev',
                  'workers.dev', 'ipfs.io', 'dweb.link', 'glitch.me', 'netlify.app',
                  'vercel.app', 'onrender.com', 'github.io', '000webhostapp.com',
                  'weebly.com', 'wixsite.com', 'square.site', 'webflow.io', 'repl.co',
                  'replit.dev', 'ngrok.io', 'ngrok-free.app', 'trycloudflare.com',
                  'herokuapp.com', 'surge.sh', 'framer.app', 'carrd.co', 'gitbook.io',
                  'notion.site', 'typedream.app', 'myportfolio.com', 'sites.google.com',
                  'forms.gle', 'jotform.com', 'formstack.com', 'dropboxusercontent.com',
                  'mediafire.com', 'wetransfer.com', 'canva.site', 'my.canva.site')
BRANDS = ('microsoft', 'office365', 'office 365', 'outlook', 'sharepoint', 'onedrive', 'teams',
          'docusign', 'adobe', 'dropbox', 'wetransfer', 'paypal', 'dhl', 'fedex', 'ups',
          'aramex', 'amazon', 'apple', 'icloud', 'google', 'zoom', 'webex', 'netflix',
          'it support', 'helpdesk', 'help desk', 'it service', 'it department', 'mail admin',
          'mailbox', 'administrator', 'payroll', 'human resources', 'voicemail', 'fax')
LURE_WORDS = ('password', 'expire', 'expiration', 'verify', 'verification', 'suspend',
              'unusual sign', 'mailbox', 'storage full', 'quota', 'voicemail', 'voice message',
              'invoice', 'payment', 'remittance', 'wire', 'swift', 'bank details', 'overdue',
              'gift card', 'urgent', 'action required', 'immediately', 'shared a document',
              'shared a file', 'secure message', 'encrypted message', 'docusign', 'e-sign',
              'purchase order', 'quotation', 'rfq', 'payroll', 'salary', 'bonus', 'tax',
              'delivery', 'shipment', 'parcel', 'mfa', 'multi-factor', 'reactivate', 'unlock')
CONTROL_CHARS = {chr(i) for i in range(32) if chr(i) not in '\t'}
BIDI = {chr(i) for i in (0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                          0x2066, 0x2067, 0x2068, 0x2069)}
ZERO_WIDTH = {chr(i) for i in (0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF)}

EOP_CATEGORIES = {
    'MALW': 'Malware', 'HPHSH': 'High-confidence phishing', 'PHSH': 'Phishing',
    'HSPM': 'High-confidence spam', 'SPM': 'Spam', 'BULK': 'Bulk mail', 'SPOOF': 'Spoofing',
    'DIMP': 'Domain impersonation', 'UIMP': 'User impersonation',
    'GIMP': 'Mailbox-intelligence impersonation', 'AMP': 'Anti-malware',
    'SAP': 'Safe Attachments (detonation)', 'FTBP': 'Blocked file type (common attachments filter)',
    'BIMP': 'Brand impersonation', 'HPHISH': 'High-confidence phishing',
    'OSPM': 'Outbound spam', 'INTOS': 'Intra-organization phishing', 'NONE': 'None',
}
EOP_SFV = {
    'BLK': "Sender is in the user's Blocked Senders list", 'NSPM': 'Not spam',
    'SFE': "Allowed: sender is in the user's Safe Senders list",
    'SKA': 'Allowed by the anti-spam policy allowed senders/domains list', 'SKB': 'Blocked by the anti-spam policy blocked senders/domains list',
    'SKI': 'Skipped: source IP is in the connection-filter IP Allow List', 'SKN': 'Bypassed spam filtering by a mail-flow (transport) rule',
    'SKQ': 'Released from quarantine', 'SKS': 'Marked spam before filtering (transport rule / on-premises verdict)', 'SPM': 'Marked as spam by spam filtering',
}

CHUNK = 256 * 1024


class ReviewError(Exception):
    pass


class PasswordError(ReviewError):
    pass


# =========================================================================== helpers
def safe(value, maxlen=240):
    """Make attacker-controlled text safe to display (no control/bidi/zero-width chars)."""
    text = str(value if value is not None else '')
    out = []
    for c in text:
        if c in CONTROL_CHARS or c in BIDI or c in ZERO_WIDTH:
            out.append(f'\\u{ord(c):04x}')
        else:
            out.append(c)
    text = ''.join(out)
    return text[:maxlen] + ('...[truncated]' if len(text) > maxlen else '')


def hashes(data: bytes) -> dict:
    return {'sha256': hashlib.sha256(data).hexdigest(),
            'sha1': hashlib.sha1(data).hexdigest(),
            'md5': hashlib.md5(data).hexdigest()}


def size_fmt(n: int) -> str:
    for unit in ('bytes', 'KB', 'MB', 'GB'):
        if n < 1024 or unit == 'GB':
            return f'{n:,} bytes' if unit == 'bytes' else f'{n:,.1f} {unit}'
        n /= 1024
    return str(n)


def ext_of(name: str) -> str:
    base = (name or '').replace('\\', '/').split('/')[-1].strip().rstrip('. ')
    return os.path.splitext(base.lower())[1]


def defang(url: str) -> str:
    u = re.sub(r'^http', 'hxxp', url, flags=re.I)
    u = re.sub(r'^ftp', 'fxp', u, flags=re.I)
    try:
        parts = urlsplit(url)
        host = parts.hostname or ''
        if host:
            u = u.replace(host, host.replace('.', '[.]'), 1)
    except ValueError:
        u = u.replace('.', '[.]')
    return u


def registrable(domain: str) -> str:
    """Rough registrable-domain guess (no public-suffix list offline)."""
    d = (domain or '').lower().strip('.')
    if re.fullmatch(r'[\d.]+', d) or ':' in d:
        return d  # IP address
    parts = d.split('.')
    if len(parts) <= 2:
        return d
    two_level = {'co', 'com', 'net', 'org', 'gov', 'edu', 'ac', 'or', 'ne', 'go', 'ltd', 'plc', 'sch'}
    if parts[-2] in two_level and len(parts[-1]) == 2:
        return '.'.join(parts[-3:])
    return '.'.join(parts[-2:])


def domain_of(addr: str) -> str:
    addr = (addr or '').strip().strip('<>')
    return addr.rsplit('@', 1)[1].lower().strip('.> ') if '@' in addr else ''


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


class Progress:
    def __init__(self, path: str | None):
        self.path = path

    def __call__(self, msg: str):
        if not self.path:
            return
        try:
            with open(self.path, 'w', encoding='utf-8') as fh:
                fh.write(msg)
        except OSError:
            pass


class Budget:
    def __init__(self):
        self.used = 0

    def take(self, n: int):
        self.used += n
        if self.used > MAX_DECODED_TOTAL:
            raise ReviewError('Total decoded-data budget exceeded; stopping to avoid a decompression bomb.')


# =========================================================================== AES (pure Python, encrypt-direction only for CTR)
def _xtime(a):
    a <<= 1
    return (a ^ 0x11B) & 0xFF if a & 0x100 else a


def _build_aes_tables():
    sbox = [0] * 256
    p = q = 1
    while True:  # generate S-box
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ (((q << 1) | (q >> 7)) & 0xFF) ^ (((q << 2) | (q >> 6)) & 0xFF) ^ \
            (((q << 3) | (q >> 5)) & 0xFF) ^ (((q << 4) | (q >> 4)) & 0xFF)
        sbox[p] = x ^ 0x63
        if p == 1:
            break
    sbox[0] = 0x63
    t0 = []
    for i in range(256):
        s = sbox[i]
        s2 = _xtime(s)
        s3 = s2 ^ s
        t0.append((s2 << 24) | (s << 16) | (s << 8) | s3)
    t1 = [((v >> 8) | (v << 24)) & 0xFFFFFFFF for v in t0]
    t2 = [((v >> 16) | (v << 16)) & 0xFFFFFFFF for v in t0]
    t3 = [((v >> 24) | (v << 8)) & 0xFFFFFFFF for v in t0]
    return sbox, t0, t1, t2, t3


_SBOX, _T0, _T1, _T2, _T3 = _build_aes_tables()


class AES:
    def __init__(self, key: bytes):
        if len(key) not in (16, 24, 32):
            raise ValueError('AES key must be 16/24/32 bytes')
        nk = len(key) // 4
        self.nr = nk + 6
        w = list(struct.unpack(f'>{nk}I', key))
        rcon = 1
        for i in range(nk, 4 * (self.nr + 1)):
            t = w[i - 1]
            if i % nk == 0:
                t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF
                t = (_SBOX[t >> 24] << 24) | (_SBOX[(t >> 16) & 255] << 16) | (_SBOX[(t >> 8) & 255] << 8) | _SBOX[t & 255]
                t ^= rcon << 24
                rcon = _xtime(rcon)
            elif nk > 6 and i % nk == 4:
                t = (_SBOX[t >> 24] << 24) | (_SBOX[(t >> 16) & 255] << 16) | (_SBOX[(t >> 8) & 255] << 8) | _SBOX[t & 255]
            w.append(w[i - nk] ^ t)
        self.rk = w

    def encrypt_block(self, block: bytes) -> bytes:
        rk, nr = self.rk, self.nr
        T0, T1, T2, T3, S = _T0, _T1, _T2, _T3, _SBOX
        s0, s1, s2, s3 = struct.unpack('>4I', block)
        s0 ^= rk[0]; s1 ^= rk[1]; s2 ^= rk[2]; s3 ^= rk[3]
        k = 4
        for _ in range(nr - 1):
            t0 = T0[s0 >> 24] ^ T1[(s1 >> 16) & 255] ^ T2[(s2 >> 8) & 255] ^ T3[s3 & 255] ^ rk[k]
            t1 = T0[s1 >> 24] ^ T1[(s2 >> 16) & 255] ^ T2[(s3 >> 8) & 255] ^ T3[s0 & 255] ^ rk[k + 1]
            t2 = T0[s2 >> 24] ^ T1[(s3 >> 16) & 255] ^ T2[(s0 >> 8) & 255] ^ T3[s1 & 255] ^ rk[k + 2]
            t3 = T0[s3 >> 24] ^ T1[(s0 >> 16) & 255] ^ T2[(s1 >> 8) & 255] ^ T3[s2 & 255] ^ rk[k + 3]
            s0, s1, s2, s3 = t0, t1, t2, t3
            k += 4
        o0 = ((S[s0 >> 24] << 24) | (S[(s1 >> 16) & 255] << 16) | (S[(s2 >> 8) & 255] << 8) | S[s3 & 255]) ^ rk[k]
        o1 = ((S[s1 >> 24] << 24) | (S[(s2 >> 16) & 255] << 16) | (S[(s3 >> 8) & 255] << 8) | S[s0 & 255]) ^ rk[k + 1]
        o2 = ((S[s2 >> 24] << 24) | (S[(s3 >> 16) & 255] << 16) | (S[(s0 >> 8) & 255] << 8) | S[s1 & 255]) ^ rk[k + 2]
        o3 = ((S[s3 >> 24] << 24) | (S[(s0 >> 16) & 255] << 16) | (S[(s1 >> 8) & 255] << 8) | S[s2 & 255]) ^ rk[k + 3]
        return struct.pack('>4I', o0, o1, o2, o3)


def winzip_aes_ctr(key: bytes, data: bytes) -> bytes:
    """WinZip AE-1/AE-2 AES-CTR: little-endian counter starting at 1."""
    aes = AES(key)
    out = bytearray()
    counter = 1
    for off in range(0, len(data), 65536):
        piece = data[off:off + 65536]
        nblocks = (len(piece) + 15) // 16
        ks = b''.join(aes.encrypt_block((counter + i).to_bytes(16, 'little')) for i in range(nblocks))
        counter += nblocks
        x = int.from_bytes(piece, 'big') ^ int.from_bytes(ks[:len(piece)], 'big')
        out += x.to_bytes(len(piece), 'big')
    return bytes(out)


# =========================================================================== ZipCrypto (traditional PKWARE)
_CRCTABLE = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ 0xEDB88320 if _c & 1 else _c >> 1
    _CRCTABLE.append(_c)


def zipcrypto_decrypt(data: bytes, password: bytes, accept_checks: set[int]):
    """Return plaintext (without 12-byte header) or None if the check byte doesn't match."""
    tbl = _CRCTABLE
    k0, k1, k2 = 0x12345678, 0x23456789, 0x34567890
    for ch in password:
        k0 = (k0 >> 8) ^ tbl[(k0 ^ ch) & 0xFF]
        k1 = (k1 + (k0 & 0xFF)) & 0xFFFFFFFF
        k1 = (k1 * 134775813 + 1) & 0xFFFFFFFF
        k2 = (k2 >> 8) ^ tbl[(k2 ^ (k1 >> 24)) & 0xFF]
    out = bytearray(len(data))
    for i, c in enumerate(data):
        t = (k2 | 2) & 0xFFFF
        p = c ^ (((t * (t ^ 1)) >> 8) & 0xFF)
        out[i] = p
        k0 = (k0 >> 8) ^ tbl[(k0 ^ p) & 0xFF]
        k1 = (k1 + (k0 & 0xFF)) & 0xFFFFFFFF
        k1 = (k1 * 134775813 + 1) & 0xFFFFFFFF
        k2 = (k2 >> 8) ^ tbl[(k2 ^ (k1 >> 24)) & 0xFF]
        if i == 11 and p not in accept_checks:
            return None
    return bytes(out[12:])


# =========================================================================== ZIP reading
def zip_encryption(info: zipfile.ZipInfo) -> str:
    if not (info.flag_bits & 0x1):
        return 'none'
    if info.compress_type == 99:
        return 'aes'
    if info.flag_bits & 0x40:
        return 'strong'   # PKWARE strong encryption - unsupported
    return 'zipcrypto'


def _aes_extra(info: zipfile.ZipInfo):
    extra = info.extra
    i = 0
    while i + 4 <= len(extra):
        hid, ln = struct.unpack('<HH', extra[i:i + 4])
        body = extra[i + 4:i + 4 + ln]
        if hid == 0x9901 and len(body) >= 7:
            vendor_version, _vid, strength, method = struct.unpack('<H2sBH', body[:7])
            return vendor_version, strength, method
        i += 4 + ln
    raise ReviewError('AES entry without WinZip AES extra field.')


def _raw_entry_bytes(zf: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    fp = zf.fp
    fp.seek(info.header_offset)
    hdr = fp.read(30)
    if len(hdr) != 30 or hdr[:4] != b'PK\x03\x04':
        raise ReviewError('Bad local file header.')
    nlen, xlen = struct.unpack('<HH', hdr[26:30])
    fp.seek(info.header_offset + 30 + nlen + xlen)
    if info.compress_size > MAX_READ_ENTRY + 1024:
        raise ReviewError('Compressed entry exceeds the inspection limit.')
    data = fp.read(info.compress_size)
    if len(data) != info.compress_size:
        raise ReviewError('Truncated archive entry.')
    return data


def _decompress(method: int, data: bytes, expected: int, limit: int) -> bytes:
    if method == 0:
        if len(data) > limit:
            raise ReviewError('Entry exceeds read limit.')
        return data
    if method == 8:
        d = zlib.decompressobj(-15)
        out = bytearray()
        buf = data
        while buf:
            out += d.decompress(buf, max(1, limit + 1 - len(out)))
            if len(out) > limit:
                raise ReviewError('Entry exceeded read limit while decompressing.')
            buf = d.unconsumed_tail
        out += d.flush()
        if len(out) > limit:
            raise ReviewError('Entry exceeded read limit while decompressing.')
        return bytes(out)
    if method == 12:
        d = bz2.BZ2Decompressor()
        out = bytearray()
        for off in range(0, len(data), 16384):
            out += d.decompress(data[off:off + 16384])
            if len(out) > limit:
                raise ReviewError('Entry exceeded read limit while decompressing.')
        return bytes(out)
    if method == 14:
        try:
            d = zipfile._get_decompressor(14)  # LZMA with ZIP header handling
        except Exception as exc:  # pragma: no cover
            raise ReviewError('LZMA support unavailable.') from exc
        out = bytearray()
        for off in range(0, len(data), 16384):
            out += d.decompress(data[off:off + 16384])
            if len(out) > limit:
                raise ReviewError('Entry exceeded read limit while decompressing.')
        return bytes(out)
    raise ReviewError(f'Unsupported ZIP compression method {method} (e.g. Deflate64).')


def read_zip_entry(zf: zipfile.ZipFile, info: zipfile.ZipInfo, budget: Budget,
                   passwords: list[str] | None = None, limit: int = MAX_READ_ENTRY):
    """Return (bytes, password_used_or_None). Raises PasswordError / ReviewError."""
    if info.file_size > limit:
        raise ReviewError(f'Entry is {size_fmt(info.file_size)}; inspection limit is {size_fmt(limit)}.')
    enc = zip_encryption(info)
    if enc == 'none':
        try:
            with zf.open(info, 'r') as fh:
                out = bytearray()
                while True:
                    chunk = fh.read(CHUNK)
                    if not chunk:
                        break
                    out += chunk
                    if len(out) > limit:
                        raise ReviewError('Entry exceeded read limit while decoding.')
        except NotImplementedError as exc:
            raise ReviewError(f'Unsupported compression in entry: {safe(exc)}') from exc
        except (zipfile.BadZipFile, OSError, EOFError, zlib.error, lzma.LZMAError, ValueError, RuntimeError) as exc:
            raise ReviewError(f'Unreadable or corrupt entry: {safe(exc)}') from exc
        budget.take(len(out))
        return bytes(out), None
    if enc == 'strong':
        raise ReviewError('PKWARE "strong encryption" is not supported.')
    cands = [p for p in (passwords or []) if p]
    if not cands:
        raise PasswordError('Entry is encrypted and no password was supplied.')
    raw = _raw_entry_bytes(zf, info)
    if enc == 'zipcrypto':
        checks = {(info.CRC >> 24) & 0xFF, (info._raw_time >> 8) & 0xFF}
        for pwd in cands:
            for enc_pwd in _password_encodings(pwd):
                plain = zipcrypto_decrypt(raw, enc_pwd, checks)
                if plain is None:
                    continue
                try:
                    data = _decompress(info.compress_type, plain, info.file_size, limit)
                except (ReviewError, zlib.error, lzma.LZMAError, OSError, EOFError, ValueError):
                    continue  # 1/256 false-positive check byte -> try next
                if (zlib.crc32(data) & 0xFFFFFFFF) != info.CRC:
                    continue
                budget.take(len(data))
                return data, pwd
        raise PasswordError('Wrong password (ZipCrypto): none of the supplied passwords produced a valid CRC.')
    # WinZip AES
    vendor_version, strength, method = _aes_extra(info)
    keylen = {1: 16, 2: 24, 3: 32}.get(strength)
    if not keylen:
        raise ReviewError('Unknown AES key strength.')
    saltlen = keylen // 2
    if len(raw) < saltlen + 2 + 10:
        raise ReviewError('AES entry too short.')
    salt, verifier, body, mac = raw[:saltlen], raw[saltlen:saltlen + 2], raw[saltlen + 2:-10], raw[-10:]
    for pwd in cands:
        for enc_pwd in _password_encodings(pwd):
            km = hashlib.pbkdf2_hmac('sha1', enc_pwd, salt, 1000, 2 * keylen + 2)
            if km[-2:] != verifier:
                continue
            ekey, mkey = km[:keylen], km[keylen:2 * keylen]
            if not hmac.compare_digest(hmac.new(mkey, body, hashlib.sha1).digest()[:10], mac):
                raise ReviewError('AES authentication code mismatch: archive is corrupt or tampered.')
            plain = winzip_aes_ctr(ekey, body)
            try:
                data = _decompress(method, plain, info.file_size, limit)
            except (zlib.error, lzma.LZMAError, OSError, EOFError, ValueError) as exc:
                raise ReviewError('Unreadable compressed data in encrypted entry.') from exc
            if vendor_version == 1 and (zlib.crc32(data) & 0xFFFFFFFF) != info.CRC:
                raise ReviewError('CRC mismatch after AES decryption.')
            budget.take(len(data))
            return data, pwd
    raise PasswordError(f'Wrong password (AES-{keylen * 8}): verifier did not match any supplied password.')


def _password_encodings(pwd: str):
    seen = []
    for enc in ('utf-8', 'cp1252', 'cp437'):
        try:
            b = pwd.encode(enc)
        except UnicodeEncodeError:
            continue
        if b not in seen:
            seen.append(b)
    return seen


def open_zip(data: bytes) -> zipfile.ZipFile:
    try:
        zf = zipfile.ZipFile(io.BytesIO(data), 'r')
    except (zipfile.BadZipFile, zipfile.LargeZipFile, OSError, ValueError) as exc:
        raise ReviewError(f'Invalid ZIP archive: {safe(exc)}') from exc
    infos = zf.infolist()
    if len(infos) > MAX_ZIP_ITEMS:
        raise ReviewError(f'Archive contains {len(infos)} entries; limit is {MAX_ZIP_ITEMS}.')
    declared = sum(max(i.file_size, 0) for i in infos)
    if declared > MAX_TOTAL_DECLARED:
        raise ReviewError(f'Archive declares {size_fmt(declared)} uncompressed; limit is {size_fmt(MAX_TOTAL_DECLARED)}.')
    return zf


# =========================================================================== content identification
def identify(data: bytes) -> tuple[str, str]:
    """Return (kind, description) from magic bytes / content sniffing."""
    p = data[:64]
    if p.startswith(b'MZ'):
        return 'pe', 'Windows executable (MZ/PE)'
    if p.startswith(b'\x7fELF'):
        return 'elf', 'Linux executable (ELF)'
    if p[:4] in (b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
        return 'macho', 'macOS executable / Java class (Mach-O or CAFEBABE)'
    if p.startswith(b'PK\x03\x04') or p.startswith(b'PK\x05\x06') or p.startswith(b'PK\x07\x08'):
        return 'zip', 'ZIP container'
    if p.startswith(b'%PDF-') or b'%PDF-' in data[:1024]:
        return 'pdf', 'PDF document'
    if p.startswith(b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'):
        return 'ole', 'OLE compound file (legacy Office / MSI / Outlook .msg)'
    if p.startswith(b'{\\rt'):
        return 'rtf', 'Rich Text Format (RTF)'
    if p.startswith(b'L\x00\x00\x00\x01\x14\x02\x00'):
        return 'lnk', 'Windows shortcut (LNK)'
    if p.startswith(b'Rar!\x1a\x07'):
        return 'rar', 'RAR archive'
    if p.startswith(b"7z\xbc\xaf'\x1c"):
        return '7z', '7-Zip archive'
    if p.startswith(b'\x1f\x8b'):
        return 'gzip', 'GZIP archive'
    if p.startswith(b'MSCF'):
        return 'cab', 'Microsoft Cabinet (CAB)'
    if p.startswith(b'\xfd7zXZ\x00'):
        return 'xz', 'XZ archive'
    if p.startswith(b'BZh'):
        return 'bzip2', 'BZIP2 archive'
    if p.startswith(b'ITSF'):
        return 'chm', 'Compiled HTML Help (CHM)'
    if p.startswith(b'\xe4\x52\x5c\x7b\x8c\xd8\xa7\x4d') or p.startswith(b'\xe4R\\{'):
        return 'onenote', 'OneNote section (.one)'
    if p.startswith(b'conectix') or data[-512:-504] == b'conectix':
        return 'vhd', 'Virtual hard disk (VHD)'
    if p.startswith(b'vhdxfile'):
        return 'vhd', 'Virtual hard disk (VHDX)'
    if len(data) > 0x8006 and data[0x8001:0x8006] == b'CD001':
        return 'iso', 'ISO 9660 disk image'
    if p.startswith(b'\x89PNG\r\n\x1a\n'):
        return 'image', 'PNG image'
    if p.startswith(b'\xff\xd8\xff'):
        return 'image', 'JPEG image'
    if p[:6] in (b'GIF87a', b'GIF89a'):
        return 'image', 'GIF image'
    if p.startswith(b'BM') and len(data) > 26:
        return 'image', 'BMP image'
    if p[:4] in (b'II*\x00', b'MM\x00*'):
        return 'image', 'TIFF image'
    if p.startswith(b'RIFF') and p[8:12] == b'WEBP':
        return 'image', 'WEBP image'
    if p.startswith(b'#!'):
        return 'script', 'Script (shebang)'
    if p.startswith(b'\x78\x9f\x3e\x22'):
        return 'tnef', 'TNEF (winmail.dat)'
    head = data[:4096].lstrip(b'\xef\xbb\xbf\xff\xfe\x00 \t\r\n').lower()
    head_nz = head.replace(b'\x00', b'')
    if head_nz.startswith(b'<svg') or (head_nz.startswith(b'<?xml') and b'<svg' in head_nz[:2048]):
        return 'svg', 'SVG image (XML, can contain script)'
    if head_nz.startswith((b'<!doctype html', b'<html', b'<head', b'<body', b'<script', b'<meta', b'<iframe', b'<form', b'<div', b'<!--')) \
            or b'<html' in head_nz[:1024] or b'<script' in head_nz[:1024]:
        return 'html', 'HTML document'
    if head_nz.startswith(b'begin:vcalendar'):
        return 'ics', 'Calendar invite (iCalendar)'
    if head_nz.startswith(b'<?xml'):
        return 'xml', 'XML document'
    if looks_like_email(data):
        return 'eml', 'Email message (RFC 822)'
    if _is_texty(data[:4096]):
        return 'text', 'Plain text'
    return 'unknown', ''


def _is_texty(b: bytes) -> bool:
    if not b:
        return False
    bad = sum(1 for c in b if c < 9 or (13 < c < 32 and c != 27))
    return bad / len(b) < 0.02


def looks_like_email(data: bytes) -> bool:
    head = data[:16384]
    if b'\n' not in head:
        return False
    lower = head.lower()
    hits = sum(1 for h in (b'\nfrom:', b'\nto:', b'\nsubject:', b'\ndate:', b'\nmessage-id:', b'\nreceived:', b'\nmime-version:', b'\nreturn-path:')
               if h in b'\n' + lower)
    return hits >= 3


EXT_FAMILY = {
    'pdf': {'.pdf'},
    'zip': {'.zip', '.docx', '.docm', '.dotx', '.dotm', '.xlsx', '.xlsm', '.xltx', '.xltm', '.xlam',
            '.pptx', '.pptm', '.potx', '.ppsx', '.ppsm', '.ppam', '.odt', '.ods', '.odp', '.jar',
            '.apk', '.vsdx', '.zipx', '.epub', '.xps', '.oxps', '.msix', '.appx', '.nupkg', '.kmz', '.onepkg'},
    'ole': {'.doc', '.dot', '.xls', '.xlt', '.ppt', '.pot', '.pps', '.msi', '.msp', '.msg', '.vsd', '.pub', '.xla', '.mst'},
    'rtf': {'.rtf', '.doc'},
    'image': {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.jfif', '.ico'},
    'html': HTML_EXT | {'.htm', '.html', '.mht', '.mhtml', '.txt', '.xml', '.aspx', '.php'},
    'svg': {'.svg', '.svgz'},
    'pe': EXEC_EXT,
}


# =========================================================================== report model
class Report:
    def __init__(self):
        self.findings: list[dict] = []
        self.errors: list[str] = []
        self._reported_errors: set[str] = set()
        self.complete = True
        self.urls: dict[str, dict] = {}

    def add(self, severity: str, code: str, title: str, detail: str = '', where: str = ''):
        key = (code, title, where)
        for f in self.findings:
            if (f['code'], f['title'], f['where']) == key:
                return
        self.findings.append({'severity': severity, 'code': code, 'title': safe(title, 300),
                              'detail': safe(detail, 600), 'where': safe(where, 300),
                              'attack': ATTACK.get(code, '')})

    def fail(self, msg: str):
        self.complete = False
        message = safe(msg, 600)
        if message not in self._reported_errors:
            self._reported_errors.add(message)
            self.errors.append(message)

    def skipped(self, node: dict, where: str, reason: str):
        node['note'] = reason
        self.fail(f'{where}: {reason}')


# =========================================================================== URL analysis
URL_RE = re.compile(r'''(?i)\b((?:https?|ftp|hxxps?)://[^\s<>"'`{}|\\^\[\]]{3,2048})''')
WWW_RE = re.compile(r'''(?i)(?<![\w/.@-])(www\.[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/[^\s<>"'`]*)?)''')


class _LinkParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []           # (url, tag, attr, anchor_text)
        self.forms = []           # action urls
        self.password_inputs = 0
        self.meta_refresh = []
        self.scripts = 0
        self.iframes = 0
        self.text = []
        self._a_stack = []
        self.hidden_text = 0
        self.imgs = 0
        self.data_imgs = 0

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or '') for k, v in attrs}
        if tag == 'a':
            href = a.get('href', '')
            self._a_stack.append([href, []])
        elif tag in ('area', 'link') and a.get('href'):
            self.links.append((a['href'], tag, 'href', ''))
        elif tag == 'form':
            self.forms.append(a.get('action', ''))
            if a.get('action'):
                self.links.append((a['action'], 'form', 'action', ''))
        elif tag == 'input' and a.get('type', '').lower() == 'password':
            self.password_inputs += 1
        elif tag == 'meta' and a.get('http-equiv', '').lower() == 'refresh':
            content = a.get('content', '')
            m = re.search(r'url\s*=\s*[\'"]?([^\'";]+)', content, re.I)
            self.meta_refresh.append(m.group(1).strip() if m else content)
            if m:
                self.links.append((m.group(1).strip(), 'meta', 'refresh', ''))
        elif tag == 'script':
            self.scripts += 1
            if a.get('src'):
                self.links.append((a['src'], 'script', 'src', ''))
        elif tag in ('iframe', 'frame', 'embed', 'object'):
            self.iframes += 1
            src = a.get('src') or a.get('data')
            if src:
                self.links.append((src, tag, 'src', ''))
        elif tag == 'img':
            w, h = a.get('width', ''), a.get('height', '')
            if not (w in ('0', '1') or h in ('0', '1')):  # ignore tracking pixels
                self.imgs += 1
            if a.get('src', '').lower().startswith('data:'):
                self.data_imgs += 1
        style = a.get('style', '').replace(' ', '').lower()
        if 'display:none' in style or 'font-size:0' in style or 'visibility:hidden' in style:
            self.hidden_text += 1

    def handle_endtag(self, tag):
        if tag == 'a' and self._a_stack:
            href, txt = self._a_stack.pop()
            if href:
                self.links.append((href, 'a', 'href', ' '.join(''.join(txt).split())[:300]))

    def handle_data(self, data):
        self.text.append(data)
        for frame in self._a_stack:
            frame[1].append(data)


def parse_html(text: str, rep: Report, where: str) -> _LinkParser:
    p = _LinkParser()
    try:
        p.feed(text[:MAX_TEXT_SCAN])
        p.close()
    except Exception:  # malformed HTML must never break the review
        rep.fail(f'{where}: HTML parsing stopped before all content was inspected.')
    return p


def _norm_url(u: str) -> str:
    u = html.unescape(u.strip().strip('"\'')).replace('\\', '/')
    u = re.sub(r'^hxxp', 'http', u, flags=re.I)
    if u.startswith('//'):
        u = 'https:' + u
    if u.lower().startswith('www.'):
        u = 'http://' + u
    return u.rstrip('.,;:!?)]}>\'"')


def add_url(rep: Report, raw: str, source: str, anchor: str = '', ctx: dict | None = None):
    url = _norm_url(raw)
    low = url.lower()
    if not url or low.startswith(('mailto:', 'tel:', 'cid:', '#', 'about:blank', 'sms:')):
        return
    if len(rep.urls) >= MAX_URLS and url not in rep.urls:
        rep.fail('Link count limit reached. Additional links were not inspected.')
        return
    flags = []
    sev = 'info'
    if low.startswith(('javascript:', 'vbscript:')):
        flags.append('script URL')
        sev = 'high'
        host = ''
    elif low.startswith('data:'):
        flags.append('data: URI (inline payload)')
        sev = 'high'
        host = ''
    elif low.startswith('file:') or low.startswith('\\\\') or low.startswith('smb:'):
        flags.append('file/SMB link (NTLM hash leak risk)')
        sev = 'high'
        host = ''
    else:
        try:
            parts = urlsplit(url)
            host = (parts.hostname or '').lower()
            port = parts.port
        except ValueError:
            return  # malformed - nothing reliable to report
        if not host:
            return
        if parts.username or '@' in (parts.netloc or ''):
            flags.append('credentials/@ in host part (obfuscation)')
            sev = 'high'
        if re.fullmatch(r'[\d.]+', host or '') or (host or '').startswith('['):
            flags.append('IP address instead of domain')
            sev = _max_sev(sev, 'medium')
        if 'xn--' in (host or ''):
            flags.append('punycode / look-alike domain')
            sev = _max_sev(sev, 'medium')
        if host in URL_SHORTENERS:
            flags.append('URL shortener (destination hidden)')
            sev = _max_sev(sev, 'low')
        if any(host == d or host.endswith('.' + d) for d in ABUSED_HOSTING):
            flags.append('free/cloud hosting often abused for phishing')
            sev = _max_sev(sev, 'low')
        if port and port not in (80, 443):
            flags.append(f'non-standard port {port}')
            sev = _max_sev(sev, 'low')
        if low.startswith('http://'):
            flags.append('unencrypted http')
        path_q = unquote(url[len(parts.scheme) + 3 + len(parts.netloc):]) if parts.scheme else ''
        if re.search(r'\.(exe|scr|js|vbs|hta|iso|img|lnk|msi|zip|rar|7z|bat|cmd|ps1)(\?|$)', path_q.lower()):
            flags.append('link points to a file download')
            sev = _max_sev(sev, 'medium')
        embedded, via = unwrap_redirect(url)
        if embedded:
            if any(w in via for w in ('safelinks', 'urldefense', 'clicktime', 'mimecast')):
                flags.append('security link wrapper (real target listed separately)')
            else:
                flags.append(f'trusted-site redirect via {via} hides the real destination')
                sev = _max_sev(sev, 'medium')
            anchor = ''
            add_url(rep, embedded, source + ' (redirect target)', '', ctx)
        elif re.search(r'(?:url|redirect|redir|goto|target|dest|next|u|q|r)=https?(%3a|:)', url, re.I):
            flags.append('open-redirect style parameter')
            sev = _max_sev(sev, 'low')
        if ctx:
            for addr in ctx.get('recipients', []):
                if not addr:
                    continue
                b64 = base64.b64encode(addr.encode()).decode().rstrip('=')
                if addr.lower() in low or unquote(low).find(addr.lower()) >= 0 or (len(b64) > 8 and b64 in url):
                    flags.append('contains the recipient email address (personalised link)')
                    sev = _max_sev(sev, 'medium')
                    break
    if anchor:
        shown = re.search(r'(?i)(?:https?://)?((?:[a-z0-9-]+\.)+[a-z]{2,})', anchor)
        if shown and host:
            shown_host = shown.group(1).lower()
            if registrable(shown_host) != registrable(host) and '.' in shown_host and not shown_host.endswith(('.png', '.jpg')):
                flags.append(f'link text shows "{safe(shown_host, 80)}" but goes elsewhere')
                sev = 'high'
    entry = rep.urls.get(url)
    if entry:
        if source not in entry['sources']:
            entry['sources'].append(source)
        for f in flags:
            if f not in entry['flags']:
                entry['flags'].append(f)
        entry['severity'] = _max_sev(entry['severity'], sev)
        return
    rep.urls[url] = {'url': safe(url, 600), 'defanged': safe(defang(url), 600), 'host': safe(host, 200),
                     'flags': flags, 'severity': sev, 'sources': [source],
                     'anchor': safe(anchor, 160)}


SEV_ORDER = {'info': 0, 'low': 1, 'medium': 2, 'high': 3}


def _max_sev(a, b):
    return a if SEV_ORDER[a] >= SEV_ORDER[b] else b


def extract_urls_from_text(rep: Report, text: str, source: str, ctx: dict):
    if len(text) > MAX_TEXT_SCAN:
        rep.fail(f'{source}: Text exceeded the link inspection limit.')
    for m in URL_RE.finditer(text[:MAX_TEXT_SCAN]):
        add_url(rep, m.group(1), source, ctx=ctx)
    for m in WWW_RE.finditer(text[:MAX_TEXT_SCAN]):
        add_url(rep, m.group(1), source, ctx=ctx)


# =========================================================================== content analyzers
def decode_text(data: bytes) -> str:
    if data[:2] in (b'\xff\xfe', b'\xfe\xff'):
        try:
            return data.decode('utf-16')
        except UnicodeDecodeError:
            pass
    if data.count(b'\x00') > len(data) // 4 and len(data) > 16:
        try:
            return data.decode('utf-16-le', errors='replace')
        except Exception:
            pass
    return data.decode('utf-8', errors='replace')


def analyze_html(rep: Report, node: dict, data: bytes, where: str, ctx: dict, is_attachment: bool):
    if len(data) > MAX_TEXT_SCAN:
        rep.skipped(node, where, 'HTML exceeded the text inspection limit.')
    text = decode_text(data[:MAX_TEXT_SCAN])
    low = text.lower()
    p = parse_html(text, rep, where)
    src = 'attachment: ' + node['name'] if is_attachment else ('message body' if ' > ' not in where else f'body of {where}')
    for url, tag, attr, anchor in p.links:
        add_url(rep, url, src + ('' if tag == 'a' else f' ({tag} {attr})'), anchor, ctx)
    extract_urls_from_text(rep, '\n'.join(p.text), src, ctx)
    if is_attachment:
        # Legit business mail rarely carries HTML/SVG attachments.
        kind = 'SVG' if node.get('kind') == 'svg' or node['ext'] == '.svg' else 'HTML'
        rep.add('medium', 'HTML_ATTACHMENT', f'{kind} file attached',
                'HTML/SVG attachments open in the browser and are a top vector for credential phishing and HTML smuggling.', where)
        node['tags'].append(f'{kind} attachment')
    smuggling = []
    if re.search(r'new\s+blob\s*\(', low):
        smuggling.append('Blob()')
    if 'createobjecturl' in low:
        smuggling.append('URL.createObjectURL')
    if 'mssaveoropenblob' in low or 'mssaveblob' in low:
        smuggling.append('msSaveOrOpenBlob')
    if re.search(r'\.download\s*=|\sdownload\s*=\s*["\']', low):
        smuggling.append('forced download attribute')
    decoders = [w for w in ('atob(', 'unescape(', 'fromcharcode', 'eval(', 'document.write(', 'decodeuricomponent(', 'crypto.subtle', 'charcodeat(') if w in low]
    if len(smuggling) >= 2 or ('Blob()' in smuggling and decoders):
        rep.add('high', 'HTML_SMUGGLING', 'HTML smuggling pattern',
                f'Script builds a file in the browser ({", ".join(smuggling)}). Used to deliver malware past email filters.', where)
        node['tags'].append('HTML smuggling')
    if p.password_inputs and (is_attachment or p.forms):
        rep.add('high', 'CRED_FORM', 'Password input form',
                f'{p.password_inputs} password field(s) inside {"the attachment" if is_attachment else "the message"}: typical credential-harvesting page.', where)
        node['tags'].append('password form')
    if p.meta_refresh or re.search(r'(window|document|top|self)\.location(\.href)?\s*=|location\.(replace|assign)\s*\(', low):
        sev = 'medium' if is_attachment else 'low'
        rep.add(sev, 'REDIRECT', 'Automatic redirect',
                'Meta refresh or script redirect sends the viewer to another page as soon as it opens.', where)
    if p.scripts and is_attachment:
        if decoders:
            rep.add('high', 'OBFUSCATED_SCRIPT', 'Obfuscated script in attachment',
                    f'{p.scripts} script block(s) using decoders: {", ".join(decoders[:6])}.', where)
        else:
            rep.add('medium', 'SCRIPT_IN_ATTACHMENT', 'Script in attachment', f'{p.scripts} script block(s).', where)
    if node.get('kind') == 'svg' and ('<script' in low or 'onload=' in low or '<foreignobject' in low):
        rep.add('high', 'SVG_ACTIVE', 'SVG with script / embedded HTML', 'SVG images should not contain scripts or foreignObject.', where)
    big_b64 = re.findall(r'[A-Za-z0-9+/]{4000,}={0,2}', text[:MAX_TEXT_SCAN])
    if big_b64 and is_attachment:
        rep.add('medium', 'EMBEDDED_BLOB', 'Large encoded blob inside file',
                f'{len(big_b64)} base64 block(s), largest {max(len(b) for b in big_b64):,} chars - possible embedded payload.', where)
    if p.iframes and is_attachment:
        rep.add('medium', 'IFRAME', 'Embedded frame', f'{p.iframes} iframe/embed element(s).', where)
    if not is_attachment and p.hidden_text >= 3:
        rep.add('low', 'HIDDEN_TEXT', 'Hidden text in message body',
                'Several elements are invisible (display:none / font-size:0) - often used to evade filters.', where)
    if re.search(r'(?i)(?:\x00|&#0*65279;|​){5,}', text[:200000]):
        rep.add('low', 'ZERO_WIDTH', 'Zero-width / padding characters', 'Used to break keyword detection.', where)
    return '\n'.join(t for t in (x.strip() for x in p.text) if t)


def analyze_pdf(rep: Report, node: dict, data: bytes, where: str, ctx: dict):
    raw = data[:MAX_TEXT_SCAN]
    # normalise #xx hex escapes in names, e.g. /J#61vaScript
    obf = len(re.findall(rb'/[A-Za-z]*#[0-9A-Fa-f]{2}', raw))
    norm = re.sub(rb'#([0-9A-Fa-f]{2})', lambda m: bytes([int(m.group(1), 16)]), raw)
    counts = {}
    for key in (b'/JavaScript', b'/JS', b'/OpenAction', b'/AA', b'/Launch', b'/EmbeddedFile',
                b'/RichMedia', b'/XFA', b'/AcroForm', b'/URI', b'/SubmitForm', b'/GoToR', b'/ObjStm', b'/Encrypt', b'/Page'):
        counts[key.decode()[1:]] = len(re.findall(re.escape(key) + rb'(?![A-Za-z])', norm))
    node['pdf'] = {k: v for k, v in counts.items() if v}
    js = counts['JavaScript'] + counts['JS']
    if counts['Launch']:
        rep.add('high', 'PDF_LAUNCH', 'PDF /Launch action', 'Can start programs or open files when the PDF is opened.', where)
    if js and (counts['OpenAction'] or counts['AA']):
        rep.add('high', 'PDF_AUTO_JS', 'PDF runs JavaScript automatically', '/JavaScript combined with /OpenAction or /AA.', where)
    elif js:
        rep.add('medium', 'PDF_JS', 'PDF contains JavaScript', f'{js} JavaScript reference(s).', where)
    if counts['EmbeddedFile']:
        rep.skipped(node, where, 'Embedded PDF files were not inspected.')
        rep.add('medium', 'PDF_EMBEDDED', 'PDF has embedded file(s)', 'Embedded files can hide executables or documents.', where)
    if counts['SubmitForm'] or (counts['AcroForm'] and counts['URI']):
        rep.add('medium', 'PDF_FORM', 'PDF form that submits data', 'Interactive form with submit / link actions.', where)
    if counts['GoToR']:
        rep.add('low', 'PDF_GOTOR', 'PDF remote GoTo action', 'Opens another (possibly remote) document.', where)
    if obf:
        rep.add('medium', 'PDF_OBFUSCATED', 'Obfuscated PDF names', f'{obf} hex-escaped PDF name(s) - common evasion trick.', where)
    if counts['Encrypt']:
        node['tags'].append('encrypted PDF')
        rep.skipped(node, where, 'Encrypted PDF content could not be inspected.')
        rep.add('low', 'PDF_ENCRYPTED', 'Encrypted PDF', 'Content is encrypted; links and scripts may be hidden from this review.', where)
    for m in re.finditer(rb'/URI\s*\(([^)]{4,2048})\)', norm):
        add_url(rep, m.group(1).decode('latin-1', errors='replace'), 'attachment: ' + node['name'], ctx=ctx)
    if counts['URI'] and counts['Page'] <= 2 and len(data) < 300 * 1024:
        rep.add('low', 'PDF_LURE', 'Short PDF with link(s)',
                '1-2 page PDF whose main content is a link: a common "click to view document" lure. Check the Links tab.', where)
    if counts['ObjStm'] and counts['URI'] == 0 and js == 0:
        node['tags'].append('object streams (content not fully visible)')
        rep.skipped(node, where, 'PDF object stream contents were not inspected.')


def analyze_ooxml(rep: Report, node: dict, zf: zipfile.ZipFile, where: str, budget: Budget, ctx: dict):
    names = [i.filename for i in zf.infolist()]
    lower = [n.lower() for n in names]
    is_office = any(n == '[content_types].xml' for n in lower)
    if not is_office:
        return False
    node['tags'].append('Office Open XML document')
    if any(n.endswith('vbaproject.bin') for n in lower):
        rep.add('high', 'MACROS', 'Document contains VBA macros', 'vbaProject.bin present. Never enable editing/content.', where)
        node['tags'].append('macros')
    if any('/embeddings/' in n for n in lower):
        rep.add('medium', 'OLE_EMBED', 'Embedded objects in document', 'word|xl|ppt/embeddings/ present (OLE objects, packages).', where)
        rep.skipped(node, where, 'Embedded Office objects were not inspected.')
    if any('activex' in n for n in lower):
        rep.add('medium', 'ACTIVEX', 'ActiveX controls in document', '', where)
    if any('externallink' in n for n in lower):
        rep.add('low', 'EXTERNAL_LINKS', 'Workbook has external links', '', where)
    for info in zf.infolist():
        n = info.filename.lower()
        if info.is_dir():
            continue
        if not n.endswith(('.rels', '.xml')):
            rep.fail(f'{where} > {info.filename}: Office component was not inspected.')
            continue
        try:
            content, _ = read_zip_entry(zf, info, budget, limit=4 * 1024 * 1024)
        except ReviewError as exc:
            rep.fail(f'{where} > {info.filename}: {exc}')
            continue
        encoding = 'utf-16' if content.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
        try:
            txt = content.decode(encoding)
        except UnicodeError:
            rep.fail(f'{where} > {info.filename}: Office XML text could not be fully decoded.')
            txt = content.decode(encoding, errors='replace')
        if n.endswith('[content_types].xml') and 'macroenabled' in txt.lower():
            rep.add('high', 'MACRO_CT', 'Macro-enabled document type', 'Content types declare a macro-enabled format.', where)
        if n.endswith('.rels'):
            for m in re.finditer(r'<Relationship\b[^>]*>', txt):
                rel = m.group(0)
                if 'TargetMode="External"' not in rel:
                    continue
                tgt = re.search(r'Target="([^"]*)"', rel)
                typ = re.search(r'Type="[^"]*/([^"/]+)"', rel)
                t = typ.group(1) if typ else '?'
                target = html.unescape(tgt.group(1)) if tgt else ''
                if t in ('attachedTemplate', 'oleObject', 'frame', 'subDocument', 'externalLinkPath'):
                    rep.add('high', 'REMOTE_TEMPLATE', f'Remote {t} reference (template injection)',
                            f'Document loads content from: {defang(target)}', where)
                if target.lower().startswith(('http', '\\\\', 'file:')):
                    add_url(rep, target, f'attachment: {node["name"]} ({t})', ctx=ctx)
        if 'ddeauto' in txt.lower() or re.search(r'instrText[^>]*>\s*DDE', txt):
            rep.add('high', 'DDE', 'DDE field in document', 'Dynamic Data Exchange can launch commands.', where)
        for m in re.finditer(r'HYPERLINK\s+&quot;([^&]+)&quot;|r:id="[^"]+"\s+[^>]*?w:history', txt):
            if m.group(1):
                add_url(rep, m.group(1), 'attachment: ' + node['name'], ctx=ctx)
    return True


def analyze_ole(rep: Report, node: dict, data: bytes, where: str):
    d = data[:MAX_TEXT_SCAN]

    def u16(s):
        return s.encode('utf-16-le')
    if u16('_VBA_PROJECT') in d or u16('VBA') + b'\x00' in d and u16('dir') in d or b'Attribute VB_' in d:
        rep.add('high', 'MACROS', 'Legacy Office file with VBA macros', 'VBA project storage found.', where)
        node['tags'].append('macros')
    if u16('Equation Native') in d or b'Equation.3' in d:
        rep.add('high', 'EQUATION', 'Equation Editor object', 'Associated with exploited CVE-2017-11882 / CVE-2018-0802.', where)
    if u16('\x01Ole10Native') in d or u16('Ole10Native') in d:
        rep.skipped(node, where, 'Embedded OLE package was not inspected.')
        rep.add('medium', 'OLE_PACKAGE', 'Embedded OLE package', 'Embedded file object inside the document.', where)
    if u16('__substg1.0_') in d:
        node['tags'].append('Outlook .msg')
        rep.skipped(node, where, 'Attached Outlook message was not parsed.')
        rep.add('medium', 'MSG_ATTACHED', 'Outlook .msg attached', 'Nested Outlook message not parsed - review it separately.', where)
    if u16('Workbook') in d and (u16('Macros') in d or b'Excel 4.0' in d or u16('Macro1') in d):
        rep.add('high', 'XLM', 'Possible Excel 4.0 (XLM) macros', '', where)
    if node['ext'] in ('.msi', '.msp'):
        rep.add('high', 'INSTALLER', 'Windows Installer package', 'MSI installers run code with high privileges.', where)


def analyze_rtf(rep: Report, node: dict, data: bytes, where: str):
    low = data[:MAX_TEXT_SCAN].lower()
    if b'\\objdata' in low or b'\\objemb' in low or b'\\objlink' in low:
        rep.skipped(node, where, 'Embedded or linked RTF object was not inspected.')
        rep.add('high', 'RTF_OBJECT', 'RTF with embedded OLE object', 'Embedded objects are a classic exploit vector.', where)
    if b'\\objupdate' in low:
        rep.add('high', 'RTF_OBJUPDATE', 'RTF auto-updating object', '\\objupdate forces the object to load on open.', where)
    if b'equation' in low:
        rep.add('high', 'EQUATION', 'Equation Editor reference in RTF', 'Associated with CVE-2017-11882.', where)


# =========================================================================== attachment / archive walking
def new_node(name: str, kind_hint: str = '') -> dict:
    return {'name': safe(name or '[unnamed]', 260), 'ext': ext_of(name or ''), 'size': None, 'mime': '',
            'kind': kind_hint, 'signature': '', 'hashes': None, 'encryption': '', 'tags': [], 'children': [],
            'note': '', 'path': ''}


def name_flags(rep: Report, node: dict, raw_name: str, where: str):
    name = raw_name or ''
    base = name.replace('\\', '/').split('/')[-1]
    ext = ext_of(base)
    lower_parts = base.lower().rstrip(' .').split('.')
    if any(c in BIDI for c in name):
        rep.add('high', 'RLO_NAME', 'Right-to-left override in filename',
                'Direction-control character can make "exe.pdf" display as "fdp.exe" etc.', where)
    if any(c in ZERO_WIDTH for c in name):
        rep.add('medium', 'ZW_NAME', 'Invisible character in filename', '', where)
    if ext in HIGH_RISK_EXT:
        rep.add('high', 'RISKY_EXT', f'High-risk file type ({ext})', 'Can run code when opened.', where)
        node['tags'].append('high-risk type')
    elif ext in HTML_EXT:
        pass  # handled by content analysis
    elif ext in ARCHIVE_EXT and ext != '.zip':
        rep.add('medium', 'ARCHIVE_TYPE', f'{ext} archive', 'Format not unpacked by this tool; contents are unknown.', where)
    elif ext in OTHER_RISKY_EXT:
        rep.add('medium', 'UNUSUAL_EXT', f'Unusual / abusable file type ({ext})', '', where)
    if len(lower_parts) >= 3 and ('.' + lower_parts[-2]) in DECOY_EXT and ext in (HIGH_RISK_EXT | HTML_EXT | ARCHIVE_EXT):
        rep.add('high', 'DOUBLE_EXT', 'Misleading double extension', f'"{safe(base, 120)}" pretends to be .{lower_parts[-2]}.', where)
    if re.search(r'\s{6,}\S', base):
        rep.add('medium', 'PADDED_NAME', 'Long whitespace padding in filename', 'Hides the real extension in narrow views.', where)
    if name.endswith((' ', '.')):
        rep.add('low', 'TRAILING', 'Trailing space/dot in filename', '', where)
    clean = name.replace('\\', '/')
    if clean.startswith('/') or (len(clean) >= 2 and clean[1] == ':') or '..' in clean.split('/'):
        rep.add('medium', 'PATH_TRAVERSAL', 'Suspicious archive path', 'Absolute path or ".." (zip-slip).', where)


def analyze_blob(rep: Report, node: dict, data: bytes, where: str, budget: Budget, ctx: dict, depth: int,
                 is_attachment: bool = True):
    """Fingerprint and deep-inspect bytes that belong to an attachment or archive entry."""
    node['where'] = where
    node['size'] = len(data)
    node['hashes'] = hashes(data)
    kind, desc = identify(data)
    node['kind'] = kind
    node['signature'] = desc
    ext = node['ext']
    text_attachment = kind in ('text', 'ics', 'xml') or ext in ('.txt', '.csv', '.ics', '.url', '.xml', '.json', '.vcf')
    if len(data) > MAX_TEXT_SCAN and (text_attachment or kind in ('pdf', 'ole', 'rtf')):
        rep.skipped(node, where, 'File exceeded the text inspection limit.')
    opaque_archive = kind in ('rar', '7z', 'gzip', 'cab', 'xz', 'bzip2')
    if ext in ARCHIVE_EXT | EXT_FAMILY['zip'] and kind != 'zip' and not opaque_archive:
        rep.skipped(node, where, 'Archive contents could not be inspected.')
    # extension vs content mismatch
    if kind in EXT_FAMILY and ext and ext not in EXT_FAMILY[kind] and kind not in ('html',) and not (kind == 'zip' and ext in ARCHIVE_EXT):
        sev = 'high' if kind in ('pe', 'elf', 'lnk', 'onenote', 'iso', 'vhd', 'chm') else 'medium'
        rep.add(sev, 'TYPE_MISMATCH', 'File content does not match its extension',
                f'Named "{ext}" but content is {desc}.', where)
    if kind == 'html' and ext and ext not in EXT_FAMILY['html'] | {'.svg', ''}:
        rep.add('high', 'TYPE_MISMATCH', 'HTML disguised as another file type', f'Named "{ext}" but content is HTML.', where)
    if kind in ('pe', 'elf', 'macho'):
        rep.add('high', 'EXECUTABLE', 'Executable program', desc, where)
    elif kind == 'lnk':
        rep.add('high', 'LNK', 'Windows shortcut file', 'LNK files can launch PowerShell/cmd with hidden arguments.', where)
    elif kind in ('iso', 'vhd'):
        rep.skipped(node, where, 'Disk image contents were not inspected.')
        rep.add('high', 'DISK_IMAGE', 'Disk image', 'ISO/IMG/VHD containers are used to bypass Mark-of-the-Web.', where)
    elif kind == 'onenote':
        rep.skipped(node, where, 'OneNote contents were not inspected.')
        rep.add('high', 'ONENOTE', 'OneNote file', 'OneNote attachments are used to deliver embedded scripts.', where)
    elif kind == 'chm':
        rep.skipped(node, where, 'Compiled Help contents were not inspected.')
        rep.add('high', 'CHM', 'Compiled HTML Help file', 'CHM files can execute scripts.', where)
    elif opaque_archive:
        rep.add('medium', 'UNINSPECTED_ARCHIVE', f'{desc} not unpacked', 'Contents are unknown to this review; treat as unverified.', where)
        rep.skipped(node, where, f'{desc} contents were not inspected.')
    elif kind == 'script':
        rep.add('high', 'SCRIPT', 'Script file', desc, where)
    elif kind == 'tnef':
        node['tags'].append('TNEF')
        rep.skipped(node, where, 'TNEF contents were not inspected.')
        rep.add('low', 'TNEF', 'winmail.dat (TNEF) attachment', 'Can wrap other attachments that are not listed here.', where)

    if kind == 'zip':
        try:
            zf = open_zip(data)
        except ReviewError as exc:
            rep.skipped(node, where, str(exc))
            rep.add('medium', 'BAD_ARCHIVE', 'Archive could not be opened', str(exc), where)
            return
        with zf:
            if analyze_ooxml(rep, node, zf, where, budget, ctx):
                return
            walk_zip(rep, node, zf, where, budget, ctx, depth + 1)
        return
    if kind == 'pdf':
        analyze_pdf(rep, node, data, where, ctx)
    elif kind in ('html', 'svg') or ext in HTML_EXT:
        analyze_html(rep, node, data, where, ctx, is_attachment)
    elif kind == 'ole':
        analyze_ole(rep, node, data, where)
    elif kind == 'rtf':
        analyze_rtf(rep, node, data, where)
    elif kind == 'eml':
        if depth >= MAX_DEPTH:
            rep.skipped(node, where, 'Nested message not parsed (depth limit).')
            return
        node['tags'].append('attached email')
        rep.add('low', 'NESTED_EMAIL', 'Email attached inside email', 'Forwarded-as-attachment or wrapper - inner message analysed below.', where)
        sub = inspect_message(rep, data, budget, ctx, where, depth + 1)
        node['children'].append(sub)
    elif text_attachment:
        txt = decode_text(data[:MAX_TEXT_SCAN])
        extract_urls_from_text(rep, txt, 'attachment: ' + node['name'], ctx)
        if ext == '.url' or '[internetshortcut]' in txt[:200].lower():
            rep.add('high', 'URL_SHORTCUT', 'Internet shortcut file', 'Opens a URL or remote share when double-clicked.', where)


def walk_zip(rep: Report, parent: dict, zf: zipfile.ZipFile, where: str, budget: Budget, ctx: dict, depth: int):
    infos = zf.infolist()
    parent['tags'].append(f'archive: {len(infos)} entr{"y" if len(infos) == 1 else "ies"}')
    if depth > MAX_DEPTH:
        rep.skipped(parent, where, 'Nesting limit reached; inner archive not opened.')
        rep.add('medium', 'DEEP_NESTING', 'Deeply nested archives', 'Archive-in-archive chains are used to evade scanners.', where)
        return
    encrypted = [i for i in infos if i.flag_bits & 1]
    if encrypted:
        rep.add('high' if ctx.get('is_attachment_chain', True) else 'medium', 'ENCRYPTED_ARCHIVE',
                'Password-protected archive', 'Encryption hides the contents from email scanning - a classic evasion technique.', where)
    for info in infos:
        child = new_node(info.filename)
        child['path'] = safe(info.filename, 260)
        cwhere = f'{where} > {safe(info.filename, 120)}'
        child['where'] = cwhere
        parent['children'].append(child)
        if info.is_dir():
            child['kind'] = 'dir'
            child['signature'] = 'Folder'
            continue
        child['declared_size'] = info.file_size
        child['packed_size'] = info.compress_size
        child['encryption'] = zip_encryption(info)
        name_flags(rep, child, info.filename, cwhere)
        ratio = info.file_size / max(1, info.compress_size)
        if ratio > 200 and info.file_size > 2_000_000:
            rep.add('medium', 'ZIP_BOMB', 'Extreme compression ratio', f'{ratio:.0f}x - possible decompression bomb; not opened.', cwhere)
            rep.skipped(child, cwhere, 'Not opened (compression ratio).')
            continue
        if info.file_size > MAX_READ_ENTRY:
            rep.add('medium', 'OVERSIZE', 'Entry too large to inspect', f'{size_fmt(info.file_size)}', cwhere)
            rep.skipped(child, cwhere, 'Not opened (size limit).')
            child['size'] = info.file_size
            continue
        if info.file_size > 50 * 1024 * 1024 or (info.file_size > 10 * 1024 * 1024 and info.compress_size < info.file_size / 50):
            rep.add('medium', 'PADDED_FILE', 'Unusually large / padded file', 'Attackers pad files to exceed scanner size limits.', cwhere)
        try:
            data, used = read_zip_entry(zf, info, budget, ctx.get('candidates'))
        except PasswordError as exc:
            rep.skipped(child, cwhere, f'Encrypted - not opened. {exc}')
            child['size'] = info.file_size
            continue
        except ReviewError as exc:
            rep.skipped(child, cwhere, f'Could not read: {exc}')
            child['size'] = info.file_size
            rep.add('low', 'UNREADABLE_ENTRY', 'Archive entry could not be read', str(exc), cwhere)
            continue
        if used is not None:
            child['tags'].append('unlocked with candidate password')
            source = 'operator' if used in ctx['supplied_passwords'] else 'message_body'
            child['unlock_source'] = source
            ctx['unlocked'].append({'where': cwhere, 'source': source})
            src = 'password you entered' if source == 'operator' else 'password text found in the message body'
            rep.add('info', 'UNLOCKED', 'Encrypted archive opened for inspection',
                    f'Unlocked in memory with the {src}.', where)
        analyze_blob(rep, child, data, cwhere, budget, ctx, depth)


# =========================================================================== header analysis
def parse_auth_results(values: list[str]) -> dict:
    out = {}
    for v in values:
        for key in ('spf', 'dkim', 'dmarc', 'compauth', 'arc'):
            m = re.search(rf'(?i)\b{key}\s*=\s*([a-z]+)', v)
            if m and key not in out:
                out[key] = m.group(1).lower()
        m = re.search(r'(?i)\breason\s*=\s*(\d+)', v)
        if m and 'reason' not in out:
            out['reason'] = m.group(1)
        m = re.search(r'(?i)action\s*=\s*([a-z]+)', v)
        if m and 'dmarc_action' not in out:
            out['dmarc_action'] = m.group(1).lower()
        m = re.search(r'(?i)header\.from\s*=\s*([^\s;]+)', v)
        if m and 'header_from' not in out:
            out['header_from'] = m.group(1)
    return out


def parse_forefront(value: str) -> dict:
    out = {}
    for part in (value or '').split(';'):
        if ':' in part:
            k, v = part.split(':', 1)
            k = k.strip().upper()
            if k in ('CIP', 'CTRY', 'LANG', 'SCL', 'SRV', 'IPV', 'SFV', 'PTR', 'CAT', 'SFTY', 'DIR', 'H', 'ARC'):
                out[k] = v.strip()
    return out


RECEIVED_IP = re.compile(r'\[(\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{6,})\]')


def is_private_ip(ip: str) -> bool:
    if ':' in ip:
        return ip.lower().startswith(('fe80', 'fc', 'fd', '::1'))
    try:
        a, b = [int(x) for x in ip.split('.')[:2]]
    except ValueError:
        return True
    return a in (10, 127) or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254) or a == 0


def analyze_headers(rep: Report, msg, where: str, ctx: dict) -> dict:
    def h(name):
        try:
            v = msg.get(name)
        except Exception:
            return ''
        return str(v) if v is not None else ''

    def h_all(name):
        try:
            return [str(v) for v in (msg.get_all(name) or [])]
        except Exception:
            return []

    headers = {}
    for name in ('From', 'Sender', 'Reply-To', 'Return-Path', 'To', 'Cc', 'Subject', 'Date', 'Message-ID',
                 'X-Mailer', 'User-Agent', 'X-Originating-IP', 'X-MS-Exchange-Organization-SCL',
                 'X-MS-Exchange-Organization-AuthAs', 'X-MS-Exchange-Organization-AuthSource',
                 'X-Microsoft-Antispam', 'X-Forefront-Antispam-Report', 'X-MS-Exchange-Organization-MessageDirectionality',
                 'List-Unsubscribe', 'List-Unsubscribe-Post', 'Precedence', 'Feedback-ID', 'X-CustomSpam', 'Authentication-Results'):
        v = h(name)
        if v:
            headers[name] = safe(v, 900)
    auth_values = h_all('Authentication-Results') + h_all('ARC-Authentication-Results')
    auth = parse_auth_results(auth_values)
    ff = parse_forefront(h('X-Forefront-Antispam-Report'))
    bcl = re.search(r'BCL:(\d+)', h('X-Microsoft-Antispam'))
    received = h_all('Received')
    hops = []
    for r in received:
        flat = ' '.join(r.split())
        ips = RECEIVED_IP.findall(flat)
        mfrom = re.search(r'(?i)\bfrom\s+(\S+)', flat)
        mby = re.search(r'(?i)\bby\s+(\S+)', flat)
        hops.append({'from': safe(mfrom.group(1) if mfrom else '', 120), 'by': safe(mby.group(1) if mby else '', 120),
                     'ip': safe(ips[0] if ips else '', 60)})
    public_ips = [hp['ip'] for hp in hops if hp['ip'] and not is_private_ip(hp['ip'])]
    origin_ip = ff.get('CIP') or (public_ips[-1] if public_ips else '')

    from_name, from_addr = parseaddr(h('From'))
    from_dom = domain_of(from_addr)
    reply_dom = domain_of(parseaddr(h('Reply-To'))[1])
    rp_dom = domain_of(parseaddr(h('Return-Path'))[1])
    rcpts = [a for _, a in getaddresses(h_all('To') + h_all('Cc')) if a]
    ctx['recipients'] = list(dict.fromkeys(ctx.get('recipients', []) + rcpts))[:20]
    rcpt_doms = {domain_of(a) for a in rcpts if domain_of(a)}

    # --- Microsoft verdict ---------------------------------------------------
    cat = ff.get('CAT', '').upper()
    if cat:
        label = EOP_CATEGORIES.get(cat, cat)
        rep.add('info', 'EOP_VERDICT', f'Microsoft filtering verdict: {label} (CAT:{cat})',
                f'SFV:{ff.get("SFV", "-")} SCL:{ff.get("SCL", "-")} - from X-Forefront-Antispam-Report.', where)
    # --- authentication -------------------------------------------------------
    if auth.get('dmarc') == 'fail':
        enforced = auth.get('reason') == '000' or auth.get('dmarc_action', '') in ('quarantine', 'reject', 'oreject', 'pct.quarantine', 'pct.reject')
        if enforced:
            rep.add('high', 'DMARC_FAIL', 'DMARC failed against an enforced policy',
                    f'{from_dom} publishes p=quarantine/reject, i.e. its owner says mail like this is not theirs. '
                    'Still check: legitimate senders sometimes forget to authorise a new mail provider.', where)
        else:
            rep.add('medium', 'DMARC_FAIL', 'DMARC failed (sender has no enforced policy)',
                    f'{from_dom} has a weak/monitor-only DMARC set-up. Very common sender misconfiguration - proves nothing on its own.', where)
    if auth.get('compauth') == 'fail':
        rep.add('medium', 'COMPAUTH_FAIL', 'Microsoft composite authentication failed', f'compauth=fail reason={auth.get("reason", "?")}', where)
    if auth.get('spf') in ('fail', 'softfail'):
        rep.add('medium', 'SPF_FAIL', f'SPF {auth["spf"]}', 'Sending server is not authorised for the envelope domain.', where)
    if auth.get('dkim') == 'fail':
        rep.add('low', 'DKIM_FAIL', 'DKIM signature failed', '', where)
    if not auth_values and ' > ' not in where:
        rep.add('info', 'NO_AUTH', 'No Authentication-Results header', 'Cannot confirm SPF/DKIM/DMARC from this copy.', where)
    # --- identity mismatches -------------------------------------------------
    if reply_dom and from_dom and registrable(reply_dom) != registrable(from_dom):
        rep.add('medium', 'REPLYTO_MISMATCH', 'Reply-To goes to a different domain', f'From {from_dom} but replies go to {reply_dom}.', where)
    if rp_dom and from_dom and registrable(rp_dom) != registrable(from_dom):
        rep.add('info', 'RETURNPATH_DIFF', 'Envelope sender differs from From', f'Return-Path {rp_dom} (normal for mailing services).', where)
    emb = re.search(r'[\w.+-]+@([\w-]+\.[\w.-]+)', from_name or '')
    if emb and from_dom and registrable(emb.group(1).lower()) != registrable(from_dom):
        rep.add('high', 'DISPLAY_SPOOF', 'Display name contains a different email address',
                f'Shows "{safe(emb.group(0), 80)}" but the real sender is {from_dom}.', where)
    lname = (from_name or '').lower()
    for b in BRANDS:
        if b in lname and b.replace(' ', '') not in from_dom.replace('-', ''):
            rep.add('medium', 'BRAND_DISPLAY', 'Display name impersonates a brand / role',
                    f'Display name "{safe(from_name, 80)}" vs sender domain {from_dom}.', where)
            break
    for rd in rcpt_doms:
        if from_dom and rd and from_dom != rd:
            a, b = registrable(from_dom).split('.')[0], registrable(rd).split('.')[0]
            if len(b) >= 4 and 0 < levenshtein(a, b) <= 2:
                rep.add('high', 'LOOKALIKE', 'Sender domain looks like the recipient domain',
                        f'{from_dom} vs {rd} - possible look-alike / typo-squat.', where)
            elif from_dom.endswith('.' + rd) is False and b in from_dom and registrable(from_dom) != registrable(rd):
                rep.add('medium', 'DOMAIN_CONTAINS', 'Sender domain contains your domain name', f'{from_dom} contains "{b}".', where)
    if 'xn--' in from_dom or any(ord(c) > 127 for c in from_dom):
        rep.add('medium', 'IDN_SENDER', 'Internationalised (punycode) sender domain', from_dom, where)
    if from_dom and rcpt_doms and registrable(from_dom) in {registrable(d) for d in rcpt_doms} and auth.get('dmarc') in ('fail', 'none') and auth.get('compauth') == 'fail':
        rep.add('high', 'INTERNAL_SPOOF', 'Spoofs your own domain', 'Claims to be internal but failed authentication.', where)
    subj = h('Subject').lower()
    lures = [w for w in LURE_WORDS if w in subj]
    if lures:
        rep.add('low', 'LURE_SUBJECT', 'Subject uses common lure wording', ', '.join(lures[:5]), where)
    if any(c in BIDI or c in ZERO_WIDTH for c in h('Subject') + (from_name or '')):
        rep.add('medium', 'HIDDEN_CHARS_HDR', 'Hidden control characters in Subject/From', '', where)

    auth_full = parse_auth_full(auth_values)
    dkim_sigs = [m.group(1) for v in h_all('DKIM-Signature') for m in [re.search(r'(?i)\bd=([^\s;]+)', v)] if m]
    align = alignment(auth_full, from_dom, dkim_sigs)
    sfty = {}
    for code in re.findall(r'9\.\d+', ff.get('SFTY', '')):
        sfty[code] = SFTY_MEANING.get(code, 'Safety tip (undocumented value)')
    if '9.25' in sfty:
        rep.add('low', 'FIRST_CONTACT', 'First contact with this sender', 'Microsoft has not seen this sender write to the recipient before.', where)
    if '9.19' in sfty or '9.20' in sfty:
        rep.add('high', 'MS_IMPERSONATION', 'Microsoft flagged impersonation', '; '.join(sfty.values()), where)
    if ff.get('IPV', '').upper() == 'CAL' or ff.get('SFV', '').upper() in ('SKA', 'SKN', 'SKI', 'SFE'):
        rep.add('info', 'FILTER_BYPASS', 'Spam filtering was bypassed by an allow rule',
                EOP_SFV.get(ff.get('SFV', '').upper(), '') or IPV_MEANING.get('CAL'), where)
    return {'auth_full': auth_full, 'alignment': align, 'sfty': sfty,
            'compauth_meaning': compauth_meaning(auth_full.get('reason', '')) if auth_full.get('compauth') else '',
            'dmarc_action': auth_full.get('dmarc_action', ''), 'ipv': IPV_MEANING.get(ff.get('IPV', '').upper(), ff.get('IPV', '')),
            'direction': DIR_MEANING.get(ff.get('DIR', '').upper(), ff.get('DIR', '')), 'custom_spam': safe(h('X-CustomSpam'), 200),
            'headers': headers, 'auth': auth, 'eop': {k: safe(v, 80) for k, v in ff.items()},
            'bcl': bcl.group(1) if bcl else '', 'received': hops[:30], 'origin_ip': safe(origin_ip, 60),
            'from_display': safe(from_name, 200), 'from_address': safe(from_addr, 200), 'from_domain': safe(from_dom, 200),
            'eop_category': EOP_CATEGORIES.get(cat, cat) if cat else '',
            'eop_sfv': EOP_SFV.get(ff.get('SFV', '').upper(), ff.get('SFV', ''))}


# =========================================================================== password candidates from body
PWD_RE = re.compile(
    r'(?i)(?:password|passcode|pass\s*word|pwd|pw|passwort|kennwort|contrase(?:ñ|n)a|mot\s+de\s+passe|senha|'
    r'parola|wachtwoord|has(?:ł|l)o|şifre|sifre|пароль|كلمة\s*(?:السر|المرور)|الرقم\s*السري|密码|密碼|パスワード)'
    r'\s*(?:is|:|=|-|–|—|：)?\s*(?:is\s*)?[:\-=]?\s*["\'“”‘’«<\[(]?\s*([^\s"\'“”‘’»>\])<]{3,40})')


def candidate_passwords(text: str) -> list[str]:
    out = []
    for m in PWD_RE.finditer(text[:400000]):
        cand = m.group(1).strip().rstrip('.,;:!')
        if cand.lower() in ('is', 'for', 'the', 'below', 'above', 'to', 'protected', 'required', 'here'):
            continue
        for c in (cand, m.group(1).strip()):
            if c and c not in out:
                out.append(c)
    return out[:MAX_PASSWORD_CANDIDATES]


def redact_report_passwords(result: dict, passwords):
    """Remove credential copies from display evidence while preserving decision codes and digests."""
    variants = {variant for password in passwords if password
                for variant in (password, safe(password, 6 * len(password)), password.replace('.', '[.]'))}
    if not variants:
        return
    pattern = re.compile('|'.join(re.escape(p) for p in sorted(variants, key=len, reverse=True)), re.IGNORECASE)

    def redact(value):
        if isinstance(value, str):
            return pattern.sub('[redacted]', value)
        if isinstance(value, list):
            return [redact(item) for item in value]
        if isinstance(value, dict):
            # These fields carry schema values or computed evidence unrelated to the supplied password.
            for key in value.keys() - {'hashes', 'kind', 'severity', 'attack', 'code', 'status', 'id',
                                       'unlock_source', 'source', 'encryption'}:
                value[key] = redact(value[key])
        return value

    result['input']['name'] = redact(result['input']['name'])
    for key in ('messages', 'other', 'findings', 'urls', 'errors', 'unlocked'):
        result[key] = redact(result[key])
    decision = result['decision']
    for row in decision['scorecard']:
        row['answer'] = redact(row['answer'])
        row['evidence'] = redact(row['evidence'])
    for check in decision['checks']:
        check['text'] = redact(check['text'])
    # A redacted URL or domain is no longer an actionable indicator. Keep the original file digest.
    iocs = decision['iocs']
    for key in ('sender', 'sender_domain', 'origin_ip'):
        if pattern.search(iocs[key]):
            iocs[key] = ''
    for key in ('urls', 'domains', 'not_blocked'):
        iocs[key] = [value for value in iocs[key] if not pattern.search(value)]
    iocs['sha256'] = [value[:64] + redact(value[64:]) for value in iocs['sha256']]
    if pattern.search(decision['spoof_pair']):
        decision['spoof_pair'] = ''


# =========================================================================== message inspection
def inspect_message(rep: Report, data: bytes, budget: Budget, ctx: dict, where: str, depth: int = 0) -> dict:
    if len(data) > MAX_EML:
        raise ReviewError(f'Message exceeds {size_fmt(MAX_EML)} limit.')
    budget.take(len(data))
    try:
        msg = BytesParser(policy=policy.default).parsebytes(data)
    except Exception as exc:
        raise ReviewError(f'Could not parse MIME message: {safe(exc)}') from exc
    node = {'kind': 'message', 'name': safe(where.split(' > ')[-1], 200), 'hashes': hashes(data), 'size': len(data),
            'children': [], 'tags': [], 'where': where}
    hinfo = analyze_headers(rep, msg, where, ctx)
    node.update(hinfo)
    if msg.defects:
        node['tags'].append(f'{len(msg.defects)} MIME defect(s)')
        if len(msg.defects) >= 3:
            rep.add('low', 'MIME_DEFECTS', 'Malformed MIME structure', ', '.join(type(d).__name__ for d in msg.defects[:5]), where)

    body_text_parts, body_html_parts = [], []
    attachments = []

    def leaves(part, level=0):
        """Walk MIME tree but treat attached messages (message/rfc822) as single attachments."""
        if level > 40:
            rep.fail(f'{where}: MIME nesting limit reached. Further parts were not inspected.')
            return
        if part.defects:
            rep.fail(f'{where}: Malformed MIME structure ({type(part.defects[0]).__name__}).')
        ctype = part.get_content_type()
        if ctype == 'message/rfc822' and part is not msg:
            yield part
            return
        if part.is_multipart():
            for sub in part.iter_parts():
                yield from leaves(sub, level + 1)
            return
        yield part

    for part in leaves(msg):
        ctype = part.get_content_type()
        try:
            filename = part.get_filename()
        except Exception:
            filename = '[invalid filename]'
        disp = part.get_content_disposition()
        if ctype == 'message/rfc822':
            attachments.append((part, filename or 'attached-message.eml', ctype, disp or 'attachment'))
            continue
        if not filename and disp != 'attachment' and ctype in ('text/plain', 'text/html'):
            try:
                payload = part.get_payload(decode=True) or b''
            except Exception:
                rep.fail(f'{where}: Message body part could not be decoded.')
                payload = b''
            if part.defects:
                rep.fail(f'{where}: Message body has a MIME decoding defect ({type(part.defects[0]).__name__}).')
            charset = part.get_content_charset() or 'utf-8'
            try:
                txt = payload.decode(charset, errors='replace')
            except LookupError:
                txt = payload.decode('utf-8', errors='replace')
            (body_html_parts if ctype == 'text/html' else body_text_parts).append(txt)
            continue
        if not filename and disp != 'attachment' and part.get('Content-ID') and ctype.startswith('image/'):
            node.setdefault('inline_images', 0)
            node['inline_images'] += 1
            filename = f'[inline image {node["inline_images"]}]'
        attachments.append((part, filename, ctype, disp))

    # --- body -----------------------------------------------------------------
    plain = '\n'.join(body_text_parts)
    visible_html = ''
    for hp in body_html_parts:
        visible_html += analyze_html(rep, node, hp.encode('utf-8', errors='replace'), where, ctx, is_attachment=False) + '\n'
    extract_urls_from_text(rep, plain, 'message body' if ' > ' not in where else f'body of {where}', ctx)
    body_for_preview = plain.strip() or re.sub(r'\n\s*\n+', '\n\n', visible_html).strip()
    hints = candidate_passwords(plain + '\n' + visible_html)
    if hints:
        node['password_hint_count'] = len(hints)
    ctx['report_passwords'].update(hints)
    preview = body_for_preview
    for secret in sorted(ctx['supplied_passwords'].union(hints), key=len, reverse=True):
        preview = preview.replace(secret, '[redacted]')
    node['body_preview'] = safe(re.sub(r'[ \t]+', ' ', preview)[:2500], 2600).replace('\\u000a', '\n')
    node['body_chars'] = len(body_for_preview)
    node['has_html'] = bool(body_html_parts)
    ctx = dict(ctx, candidates=list(dict.fromkeys(ctx['user_passwords'] + hints)))
    body_lower = (plain + visible_html).lower()
    if re.search(r'(?i)(qr\s*code|scan\s+(the|this)\s+(code|qr))', body_lower):
        rep.add('medium', 'QR_LURE', 'Message asks you to scan a QR code',
                'QR-code phishing ("quishing") moves the link to a phone, outside company protection. QR images are not decoded by this tool.', where)

    # --- attachments ---------------------------------------------------------
    for idx, (part, filename, ctype, disp) in enumerate(attachments, 1):
        an = new_node(filename or f'[unnamed {ctype}]')
        an['mime'] = safe(ctype, 100)
        an['disposition'] = disp or ''
        awhere = f'{where} > {safe(filename or "[unnamed]", 120)}'
        an['where'] = awhere
        node['children'].append(an)
        name_flags(rep, an, filename or '', awhere)
        try:
            if ctype == 'message/rfc822':
                inner = part.get_payload()
                inner = inner[0] if isinstance(inner, list) and inner else inner
                payload = inner.as_bytes(policy=policy.default.clone(max_line_length=0)) if hasattr(inner, 'as_bytes') else None
            else:
                payload = part.get_payload(decode=True)
        except Exception as exc:
            rep.skipped(an, awhere, f'Could not decode attachment: {safe(exc)}')
            rep.add('low', 'DECODE_FAIL', 'Attachment could not be decoded', str(exc), awhere)
            continue
        if payload is None:
            rep.skipped(an, awhere, 'No decodable bytes (MIME encoding issue).')
            continue
        if part.defects:
            rep.skipped(an, awhere, f'MIME decoding defect ({type(part.defects[0]).__name__}).')
        if len(payload) > MAX_ATTACHMENT:
            an['size'] = len(payload)
            rep.skipped(an, awhere, 'Too large to inspect.')
            rep.add('medium', 'OVERSIZE', 'Attachment too large to inspect', size_fmt(len(payload)), awhere)
            continue
        try:
            budget.take(len(payload))
            analyze_blob(rep, an, payload, awhere, budget, ctx, depth)
        except ReviewError as exc:
            rep.skipped(an, awhere, str(exc))
        # mime type vs content
        if an.get('kind') == 'pe' and not ctype.startswith('application/'):
            rep.add('high', 'MIME_MISMATCH', 'Executable declared as non-application MIME type', ctype, awhere)
    node['attachment_count'] = len(attachments) - node.get('inline_images', 0)
    stats = {'html': bool(body_html_parts), 'imgs': 0, 'data_imgs': 0, 'visible_chars': len(re.sub(r'\s+', '', visible_html + plain))}
    for hp in body_html_parts:
        pp = parse_html(hp, rep, where)
        stats['imgs'] += pp.imgs
        stats['data_imgs'] += pp.data_imgs
    if body_html_parts:
        stats['visible_chars'] = len(re.sub(r'\s+', '', visible_html))
    analyze_message_signals(rep, node, msg, where, ctx, plain + '\n' + visible_html, stats)
    return node


# =========================================================================== Microsoft verdict reference
# Source: learn.microsoft.com/defender-office-365/message-headers-eop-mdo (official field/value tables)
MS_MALWARE = {'MALW', 'AMP', 'SAP'}
MS_HIGH_PHISH = {'HPHSH', 'HPHISH'}
MS_PHISH = {'PHSH', 'SPOOF', 'DIMP', 'UIMP', 'GIMP', 'BIMP', 'INTOS'}
MS_SPAM = {'SPM', 'HSPM', 'OSPM'}
MS_BULK = {'BULK'}
SFTY_MEANING = {
    '9.19': 'Domain impersonation: the sending domain impersonates a protected domain',
    '9.20': 'User impersonation: the sender impersonates a user in your org or a protected user',
    '9.25': 'First contact: the recipient has not received mail from this sender before',
}
IPV_MEANING = {'CAL': 'Skipped filtering - source IP is in your IP Allow List',
               'NLI': 'Source IP not on any reputation list'}
DIR_MEANING = {'INB': 'Inbound', 'OUT': 'Outbound', 'INT': 'Internal'}
COMPAUTH_REASONS = {
    '000': 'Failed explicit authentication: DMARC failed and the domain publishes p=quarantine or p=reject',
    '001': 'Failed implicit authentication: no or weak SPF/DKIM/DMARC records (e.g. ~all, ?all, p=none)',
    '002': 'Your organisation explicitly prohibits this sender/domain pair (admin spoof block)',
    '010': 'DMARC p=reject/quarantine failed for one of YOUR accepted domains (intra-org spoofing)',
    '100': 'Passed: SPF passed, or DKIM passed with aligned domains',
    '101': 'Passed: DKIM signed by the From domain',
    '102': 'Passed: MAIL FROM and From aligned and SPF passed',
    '103': 'Passed: From domain aligns with the connecting IP PTR record',
    '104': 'Passed: connecting IP PTR aligns with the From domain',
    '108': 'Passed: DKIM broken only by legitimate earlier hops',
    '109': 'Passed: no DMARC record, but the message would pass',
    '111': 'Passed: DMARC temp/perm error but SPF or DKIM aligns',
    '112': 'Passed: DMARC record lookup timed out',
    '115': 'Passed: sent from a Microsoft 365 org that owns the From domain',
    '116': 'Passed: From domain MX aligns with the connecting IP PTR',
    '130': 'Passed: a trusted ARC sealer overrode a DMARC failure',
    '201': 'Soft pass: From domain PTR aligns with the connecting IP subnet',
    '202': 'Soft pass: From domain aligns with the connecting IP PTR domain',
    '501': 'Not enforced: valid NDR, prior contact established',
    '502': 'Not enforced: valid NDR for a message sent from your organisation',
    '601': 'Failed: the From domain is one of YOUR accepted domains (self/intra-org spoofing)',
    '905': 'Not enforced: complex routing (on-premises Exchange or a third-party service in front of Microsoft 365)',
}


def compauth_meaning(code: str) -> str:
    code = (code or '').strip()
    if code in COMPAUTH_REASONS:
        return COMPAUTH_REASONS[code]
    if not code:
        return ''
    head = code[0]
    return {'1': 'Passed composite authentication', '2': 'Soft-passed implicit authentication',
            '3': 'Not checked for composite authentication', '4': 'Composite authentication bypassed',
            '6': 'Failed implicit authentication', '7': 'Passed: org has history of legitimate mail from this infrastructure (DMARC not enforced)',
            '9': 'Composite authentication bypassed'}.get(head, 'Undocumented reason code')


def bcl_band(bcl: str) -> str:
    try:
        n = int(bcl)
    except (TypeError, ValueError):
        return ''
    if n == 0:
        return 'not bulk'
    if n <= 3:
        return 'bulk sender with few complaints'
    if n <= 7:
        return 'bulk sender with mixed complaints'
    return 'bulk sender with many complaints'


# =========================================================================== authentication & alignment (DMARC, RFC 9989)
def parse_auth_full(values: list[str]) -> dict:
    """Parse the receiving server's Authentication-Results (topmost Microsoft one preferred)."""
    chosen = ''
    for v in values:
        if 'compauth' in v.lower():
            chosen = v
            break
    if not chosen and values:
        chosen = values[0]
    flat = ' '.join(chosen.split())
    out = {'raw': safe(flat, 900), 'spf': '', 'mailfrom': '', 'dkim': [], 'dmarc': '', 'dmarc_action': '',
           'header_from': '', 'compauth': '', 'reason': '', 'arc': ''}
    m = re.search(r'(?i)\bspf=(\w+)', flat)
    if m:
        out['spf'] = m.group(1).lower()
    m = re.search(r'(?i)smtp\.mailfrom=([^\s;]+)', flat)
    if m:
        out['mailfrom'] = m.group(1).lower().strip('<>')
    for m in re.finditer(r'(?i)\bdkim=(\w+)(?:\s*\([^)]*\))?\s*(?:header\.d=([^\s;]+))?', flat):
        out['dkim'].append({'result': m.group(1).lower(), 'domain': (m.group(2) or '').lower()})
    m = re.search(r'(?i)\bdmarc=(\w+)', flat)
    if m:
        out['dmarc'] = m.group(1).lower()
    m = re.search(r'(?i)\baction=([\w.]+)', flat)
    if m:
        out['dmarc_action'] = m.group(1).lower()
    m = re.search(r'(?i)header\.from=([^\s;]+)', flat)
    if m:
        out['header_from'] = m.group(1).lower()
    m = re.search(r'(?i)\bcompauth=(\w+)', flat)
    if m:
        out['compauth'] = m.group(1).lower()
    m = re.search(r'(?i)\breason=(\d{3})', flat)
    if m:
        out['reason'] = m.group(1)
    m = re.search(r'(?i)\barc=(\w+)', flat)
    if m:
        out['arc'] = m.group(1).lower()
    return out


def alignment(auth: dict, from_dom: str, dkim_sig_domains: list[str]) -> dict:
    org = registrable(from_dom) if from_dom else ''
    spf_aligned = bool(org and auth.get('spf') == 'pass' and auth.get('mailfrom') and
                       registrable(domain_of('x@' + auth['mailfrom'].split('@')[-1])) == org)
    dkim_aligned = bool(org and any(d['result'] == 'pass' and d['domain'] and registrable(d['domain']) == org for d in auth.get('dkim', [])))
    dkim_pass_any = any(d['result'] == 'pass' for d in auth.get('dkim', []))
    return {'spf_aligned': spf_aligned, 'dkim_aligned': dkim_aligned, 'dkim_pass': dkim_pass_any,
            'aligned': spf_aligned or dkim_aligned,
            'dkim_signers': sorted({registrable(d) for d in dkim_sig_domains if d})[:6]}


# =========================================================================== social-engineering vocabulary (EN + AR)
FREEMAIL = {'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'msn.com', 'yahoo.com',
            'ymail.com', 'aol.com', 'icloud.com', 'me.com', 'mac.com', 'proton.me', 'protonmail.com', 'pm.me',
            'gmx.com', 'gmx.de', 'gmx.net', 'mail.com', 'yandex.ru', 'yandex.com', 'zoho.com', 'zohomail.com',
            'tutanota.com', 'tuta.io', 'mail.ru', 'inbox.ru', 'qq.com', '163.com', '126.com', 'hotmail.co.uk',
            'yahoo.co.uk', 'outlook.sa', 'hotmail.fr', 'web.de', 'seznam.cz', 'rediffmail.com'}
ESP_DOMAINS = ('mailchimp', 'mcsv.net', 'mcdlv.net', 'rsgsv.net', 'sendgrid', 'amazonses.com', 'mailgun',
               'sparkpostmail.com', 'sparkpost', 'hubspotemail.net', 'hubspot', 'exacttarget.com', 'sfmc',
               'salesforce.com', 'constantcontact', 'sendinblue', 'brevo', 'mailjet', 'postmarkapp', 'klaviyo',
               'createsend', 'cmail', 'zcsend.net', 'zohocampaigns', 'mktomail.com', 'marketo', 'braze',
               'iterable', 'customer.io', 'mandrillapp', 'emarsys', 'acoustic', 'sailthru', 'smtp2go',
               'elasticemail', 'mailerlite', 'convertkit', 'activecampaign', 'getresponse', 'moosend', 'omnisend')
LURES = {
    'payment_change': ('change of bank', 'bank details have changed', 'new bank details', 'updated bank', 'banking details',
                       'new account details', 'change our account', 'update our payment', 'remit to our new',
                       'new remittance', 'account has been changed', 'payment instructions', 'wire transfer', 'swift copy',
                       'iban', 'تغيير الحساب', 'حساب بنكي جديد', 'بيانات الحساب البنكي', 'تحويل بنكي', 'تحديث بيانات الدفع'),
    'gift_card': ('gift card', 'giftcard', 'itunes card', 'apple card', 'google play card', 'steam card', 'amazon card',
                  'scratch the back', 'card codes', 'بطاقات هدايا', 'كروت شحن'),
    'urgency': ('urgent', 'immediately', 'asap', 'right away', 'within 24 hours', 'today only', 'final notice',
                'last warning', 'suspended', 'will be closed', 'will be deleted', 'expires today', 'action required',
                'عاجل', 'فورا', 'فوراً', 'خلال 24 ساعة', 'سيتم إيقاف', 'إجراء مطلوب'),
    'secrecy': ('keep this confidential', 'keep it confidential', "don't tell", 'do not tell', 'between us',
                'discreet', 'not discuss this', 'سري', 'لا تخبر'),
    'availability': ('are you available', 'are you at your desk', 'are you in the office', 'quick task',
                     'i need a favor', 'i need a favour', 'send me your whatsapp', 'your mobile number',
                     'your cell number', 'reply with your number', 'هل أنت متاح', 'رقم الواتساب'),
    'credential': ('verify your account', 'confirm your account', 'confirm your identity', 'password will expire',
                   'password expires', 'reset your password', 'update your password', 're-validate', 'revalidate',
                   'mailbox is full', 'storage is full', 'quota', 'unusual sign-in', 'sign in to view', 'login to view',
                   'log in to view', 'mfa', 'multi-factor', 'two-factor', 'كلمة المرور', 'تحقق من حسابك', 'تسجيل الدخول'),
    'doc_share': ('shared a file', 'shared a document', 'has shared', 'shared with you', 'view document', 'review document',
                  'open document', 'secure document', 'secure message', 'encrypted message', 'e-signature', 'esign',
                  'please sign', 'review and sign', 'docusign', 'adobe sign', 'sharepoint', 'onedrive', 'dropbox',
                  'voicemail', 'voice message', 'fax', 'scanned document', 'مستند مشترك'),
    'callback': ('subscription', 'auto-renew', 'auto renewal', 'renewal', 'has been charged', 'will be charged',
                 'charged to your', 'refund', 'cancel your order', 'to cancel', 'order confirmation', 'invoice',
                 'did not authorize', "didn't authorize", 'not authorized this', 'geek squad', 'norton', 'mcafee',
                 'antivirus', 'paypal', 'helpline', 'customer support', 'toll free', 'toll-free', 'call us', 'call our',
                 'contact our billing', 'billing department', 'اتصل', 'خدمة العملاء', 'اشتراك', 'استرداد'),
}
PHONE_RE = re.compile(r'(?<![\w+/.])(\+?\(?\d{1,4}\)?(?:[\s.\-]?\(?\d{2,5}\)?){2,5})(?![\w/])')
IBAN_RE = re.compile(r'\b([A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?)\b')
BRAND_DOMAINS = {
    'microsoft': ('microsoft.com', 'office.com', 'sharepoint.com', 'live.com', 'microsoftonline.com', 'outlook.com',
                  'office365.com', '1drv.ms', 'cloud.microsoft', 'microsoft365.com', 'msft.net', 'azure.com', 'teams.microsoft.com'),
    'sharepoint': ('sharepoint.com', 'microsoft.com', 'office.com', 'cloud.microsoft'),
    'onedrive': ('onedrive.live.com', 'live.com', 'sharepoint.com', '1drv.ms', 'microsoft.com', 'cloud.microsoft'),
    'docusign': ('docusign.net', 'docusign.com'),
    'adobe': ('adobe.com', 'acrobat.com', 'adobesign.com', 'echosign.com'),
    'dropbox': ('dropbox.com', 'db.tt', 'dropboxusercontent.com'),
    'google': ('google.com', 'goo.gl', 'googleusercontent.com', 'gstatic.com', 'youtube.com'),
    'paypal': ('paypal.com', 'paypal.me', 'paypalobjects.com'),
    'dhl': ('dhl.com', 'dhl.de', 'dhl.co.uk', 'dhlparcel.nl'),
    'aramex': ('aramex.com',),
    'fedex': ('fedex.com',),
    'wetransfer': ('wetransfer.com', 'we.tl'),
}
TRUSTED_REDIRECTORS = {
    'google.': ('/url', '/amp/'), 'bing.com': ('/ck/a',), 'youtube.com': ('/redirect',), 'linkedin.com': ('/slink', '/redir'),
    'facebook.com': ('/l.php',), 'doubleclick.net': ('',), 'googleadservices.com': ('',), 't.co': ('',),
    'mail.google.com': ('/url',), 'safelinks.protection.outlook.com': ('',), 'urldefense.com': ('',),
    'urldefense.proofpoint.com': ('',), 'clicktime.symantec.com': ('',), 'mimecastprotect.com': ('',),
}
ATTACK = {
    'RISKY_EXT': 'T1566.001', 'EXECUTABLE': 'T1566.001', 'MACROS': 'T1566.001', 'REMOTE_TEMPLATE': 'T1221',
    'HTML_SMUGGLING': 'T1027.006', 'LNK': 'T1566.001', 'DISK_IMAGE': 'T1553.005', 'ONENOTE': 'T1566.001',
    'ENCRYPTED_ARCHIVE': 'T1027.013', 'DOUBLE_EXT': 'T1036.007', 'RLO_NAME': 'T1036.002', 'TYPE_MISMATCH': 'T1036.008',
    'CRED_FORM': 'T1598.003', 'CRED_LURE': 'T1598.003', 'DOC_LURE': 'T1566.002', 'BRAND_LINK_MISMATCH': 'T1566.002',
    'CALLBACK': 'T1566.004', 'BEC_PAYMENT': 'T1657', 'GIFT_CARD': 'T1657', 'DISPLAY_SPOOF': 'T1566',
    'LOOKALIKE': 'T1583.001', 'LOOKALIKE_LINK': 'T1583.001', 'HOMOGLYPH': 'T1583.001', 'VIP_IMPERSONATION': 'T1566', 'REDIRECT_ABUSE': 'T1566.002',
    'QR_LURE': 'T1566.002', 'IMAGE_ONLY': 'T1566.002', 'PDF_AUTO_JS': 'T1566.001', 'DDE': 'T1559.002',
}


def _script_of(ch: str) -> str:
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return ''
    for s in ('LATIN', 'CYRILLIC', 'GREEK', 'ARMENIAN', 'CHEROKEE'):
        if name.startswith(s):
            return s
    return ''


def mixed_script_words(text: str) -> list[str]:
    hits = []
    for word in re.findall(r'\w{3,}', text or ''):
        scripts = {_script_of(c) for c in word if c.isalpha()} - {''}
        if len(scripts) > 1 and 'LATIN' in scripts:
            hits.append(word)
    return hits[:5]


def iban_valid(raw: str) -> bool:
    s = raw.replace(' ', '')
    if not (15 <= len(s) <= 34):
        return False
    s = s[4:] + s[:4]
    num = ''.join(str(int(c, 36)) for c in s)
    try:
        return int(num) % 97 == 1
    except ValueError:
        return False


def find_phones(text: str) -> list[str]:
    out = []
    for m in PHONE_RE.finditer(text):
        raw = m.group(1).strip()
        digits = re.sub(r'\D', '', raw)
        if not (9 <= len(digits) <= 15):
            continue
        if re.fullmatch(r'(19|20)\d{6}', digits) or len(set(digits)) <= 2:
            continue  # dates / filler
        if raw not in out:
            out.append(raw)
    return out[:8]


def lure_hits(text_low: str, group: str) -> list[str]:
    return [w for w in LURES[group] if w in text_low]


def unwrap_redirect(url: str):
    """Return (embedded_target, redirector_host) for well-known redirectors/link wrappers."""
    try:
        parts = urlsplit(url)
    except ValueError:
        return None, ''
    host = (parts.hostname or '').lower()
    for key, paths in TRUSTED_REDIRECTORS.items():
        if (host == key or host.endswith('.' + key) or (key.endswith('.') and (host.startswith(key) or ('.' + key) in host))):
            if any(parts.path.startswith(p) for p in paths):
                from urllib.parse import parse_qs
                qs = parse_qs(parts.query)
                for k in ('url', 'q', 'u', 'adurl', 'dest', 'target', 'redirect', 'redir'):
                    for v in qs.get(k, []):
                        v = unquote(v)
                        if k == 'u' and v.startswith('a1'):
                            try:
                                v = base64.urlsafe_b64decode(v[2:] + '==').decode('utf-8', 'replace')
                            except (ValueError, binascii.Error):
                                pass
                        if v.lower().startswith(('http://', 'https://')):
                            return v, host
                m = re.search(r'/amp/s/(.+)$', parts.path)
                if m:
                    return 'https://' + m.group(1), host
    return None, ''


# =========================================================================== message-level analysis (no attachment needed)
def analyze_message_signals(rep: 'Report', node: dict, msg, where: str, ctx: dict, text: str, body: dict):
    hinfo = node
    from_dom = hinfo.get('from_domain', '')
    from_name = hinfo.get('from_display', '')
    subj = hinfo.get('headers', {}).get('Subject', '')
    cfg = ctx.get('config', {})
    org_domains = {d.lower() for d in cfg.get('org_domains', [])}
    vip_names = [v.lower() for v in cfg.get('vip_display_names', []) if v]
    partner_domains = {d.lower() for d in cfg.get('trusted_partner_domains', [])}
    tenants = {t.lower() for t in cfg.get('m365_tenant_names', [])}
    full = f'{subj}\n{text}'
    low = full.lower()
    msg_urls = [u for u in rep.urls.values() if any(s == 'message body' or s.startswith('body of ' + where) or s.startswith('attachment') for s in u['sources'])]
    body_urls = [u for u in rep.urls.values() if any(s in ('message body', f'body of {where}') for s in u['sources'])]
    from_is_free = registrable(from_dom) in FREEMAIL or from_dom in FREEMAIL
    from_is_org = bool(org_domains) and registrable(from_dom) in {registrable(d) for d in org_domains}
    signals = {}

    # --- impersonation of your people / organisation
    if vip_names and not from_is_org:
        for v in vip_names:
            if v and v in (from_name or '').lower():
                rep.add('high', 'VIP_IMPERSONATION', 'External sender uses the name of one of your executives',
                        f'Display name "{safe(from_name, 60)}" comes from {from_dom}, not from your domain.', where)
                signals['vip'] = True
                break
    if from_is_free:
        roles = ('ceo', 'cfo', 'director', 'manager', 'finance', 'accounts', 'payroll', 'hr ', 'human resources',
                 'it support', 'helpdesk', 'admin', 'bank', 'invoice', 'billing', 'مدير', 'المالية')
        orgword = any(registrable(d).split('.')[0] in (from_name or '').lower() for d in org_domains) if org_domains else False
        if orgword or any(r in (from_name or '').lower() for r in roles):
            rep.add('medium', 'FREEMAIL_ROLE', 'Free webmail account using a company/role name',
                    f'"{safe(from_name, 60)}" <{from_dom}>: businesses rarely use free webmail for this.', where)
        signals['freemail'] = True
    reply_dom = domain_of(parseaddr(hinfo.get('headers', {}).get('Reply-To', ''))[1])
    if reply_dom and (registrable(reply_dom) in FREEMAIL) and not from_is_free:
        rep.add('high', 'REPLYTO_FREEMAIL', 'Replies are redirected to a free webmail account',
                f'From {from_dom}, Reply-To {reply_dom}: classic BEC set-up.', where)
        signals['reply_freemail'] = True
    for label, s in (('display name', from_name), ('subject', subj), ('sender domain', from_dom)):
        mixed = mixed_script_words(s)
        if mixed:
            rep.add('high' if label == 'sender domain' else 'medium', 'HOMOGLYPH', f'Look-alike characters in the {label}',
                    f'Mixed Latin/Cyrillic/Greek letters: {", ".join(safe(m, 40) for m in mixed)}', where)
    for u in body_urls:
        host = u['host']
        if mixed_script_words(host):
            rep.add('high', 'HOMOGLYPH', 'Look-alike characters in a link domain', u['defanged'], where)
        if org_domains and host and registrable(host) not in {registrable(d) for d in org_domains}:
            for od in org_domains:
                a, b = registrable(host).split('.')[0], registrable(od).split('.')[0]
                if len(b) >= 4 and 0 < levenshtein(a, b) <= 2:
                    rep.add('high', 'LOOKALIKE_LINK', 'Link to a domain that imitates yours (typo-squat)', f'{u["defanged"]} vs {od}', where)
                    break
                if len(b) >= 4 and b in a and a != b:
                    rep.add('medium', 'LOOKALIKE_LINK', 'Link domain contains your company name', f'{u["defanged"]} vs {od} - verify it really belongs to you or a partner', where)
                    break

    # --- BEC / payment fraud
    pay = lure_hits(low, 'payment_change')
    ibans = [i for i in IBAN_RE.findall(full) if iban_valid(i)]
    gift = lure_hits(low, 'gift_card')
    urg = lure_hits(low, 'urgency')
    sec = lure_hits(low, 'secrecy')
    avail = lure_hits(low, 'availability')
    if ibans:
        node['ibans'] = [safe(i, 40) for i in ibans[:3]]
    if (pay and (ibans or urg or sec)) or (ibans and not from_is_org and (urg or 'invoice' in low)):
        rep.add('high', 'BEC_PAYMENT', 'Request to pay or change bank details',
                f'Payment wording ({", ".join(pay[:3]) or "IBAN"}){" with a valid IBAN" if ibans else ""}. Verify by phone with a number you already have.', where)
        signals['bec'] = True
    elif pay:
        rep.add('medium', 'BEC_PAYMENT', 'Mentions payments or bank details', ', '.join(pay[:4]), where)
        signals['payment'] = True
    if gift:
        rep.add('high', 'GIFT_CARD', 'Gift-card request', ', '.join(gift[:3]) + ' - a classic executive-impersonation scam.', where)
        signals['bec'] = True
    if avail and not from_is_org and len(text) < 1200:
        rep.add('medium', 'BEC_OPENER', 'Short "are you available?" style opener',
                'Typical first step of CEO / gift-card fraud: the real request follows once you reply.', where)
        signals['bec_opener'] = True
    if sec and (pay or gift):
        rep.add('high', 'SECRECY', 'Asks for secrecy around a payment', ', '.join(sec[:3]), where)

    # --- callback phishing (TOAD): phone number + billing/support lure, few or no links
    phones = find_phones(text)
    cb = lure_hits(low, 'callback')
    if phones:
        node['phones'] = [safe(p, 30) for p in phones]
    if phones and len(cb) >= 2 and len(body_urls) <= 3:
        rep.add('high', 'CALLBACK', 'Callback scam pattern (call this number)',
                f'Phone number(s) {", ".join(phones[:2])} with billing/support wording ({", ".join(cb[:4])}). '
                'Victims are talked into installing remote-access tools or paying.', where)
        signals['callback'] = True
    elif phones and cb and not body_urls and not node.get('children'):
        rep.add('medium', 'CALLBACK', 'Asks you to call a phone number', f'{", ".join(phones[:2])} - {", ".join(cb[:3])}', where)
        signals['callback'] = True

    # --- credential / document-share lures
    cred = lure_hits(low, 'credential')
    docs = lure_hits(low, 'doc_share')
    link_hosts = [u['host'] for u in body_urls if u['host']]
    mentioned = [b for b in BRAND_DOMAINS if b in low or b in (from_name or '').lower()]
    for brand in mentioned:
        legit = BRAND_DOMAINS[brand]
        if link_hosts and not any(any(h == d or h.endswith('.' + d) for d in legit) for h in link_hosts) and \
                not any(registrable(from_dom) == registrable(d) for d in legit):
            rep.add('high' if (docs or cred) else 'medium', 'BRAND_LINK_MISMATCH',
                    f'Mentions {brand.title()} but no link goes to {brand.title()}',
                    f'Links go to: {", ".join(sorted(set(registrable(h) for h in link_hosts))[:4])}', where)
            signals['cred'] = True
            break
    if (cred or docs) and body_urls:
        risky = [u for u in body_urls if u['severity'] in ('medium', 'high')]
        if risky or not from_is_org:
            rep.add('high' if risky else 'medium', 'CRED_LURE' if cred else 'DOC_LURE',
                    'Sign-in / account lure with a link' if cred else 'Document-share / e-signature lure with a link',
                    f'Wording: {", ".join((cred + docs)[:4])}. Real services rarely ask you to sign in from an email link.', where)
            signals['cred'] = True
    for u in body_urls:
        h = u['host']
        if h.endswith('.sharepoint.com'):
            t = h.split('.')[0].replace('-my', '')
            if t and tenants and t not in tenants:
                rep.add('medium', 'EXTERNAL_TENANT', 'Document hosted in another organisation\'s Microsoft 365',
                        f'{u["defanged"]} - common when a partner mailbox is compromised. Confirm with the sender.', where)
        if 'trusted-site redirect' in ' '.join(u['flags']):
            rep.add('medium', 'REDIRECT_ABUSE', 'Trusted website used to redirect to the real destination', u['defanged'], where)

    # --- image-only / QR
    if body.get('html') and body.get('imgs', 0) >= 1 and body.get('visible_chars', 0) < 80 and body_urls:
        rep.add('medium', 'IMAGE_ONLY', 'Message is mostly an image with a link',
                'Text inside images is invisible to filters (and to this tool). Common for QR and fake-button phishing.', where)
    if body.get('data_imgs'):
        node['tags'].append('inline data: images')

    # --- bulk / graymail assessment (Gmail/Yahoo 2024, Outlook.com May 2025 requirements; RFC 8058 one-click)
    hd = {k.lower(): v for k, v in hinfo.get('headers', {}).items()}
    lu = hd.get('list-unsubscribe', '')
    lup = hd.get('list-unsubscribe-post', '')
    prec = hd.get('precedence', '').lower()
    paths = ' '.join([hinfo.get('auth_full', {}).get('mailfrom', '')] + hinfo.get('alignment', {}).get('dkim_signers', []) +
                     [h.get('from', '') + ' ' + h.get('by', '') for h in hinfo.get('received', [])]).lower()
    esp = next((e for e in ESP_DOMAINS if e in paths), '')
    eop = hinfo.get('eop', {})
    is_bulk = (eop.get('CAT', '').upper() == 'BULK' or 'BULK' in eop.get('SRV', '').upper()
               or (lu and (esp or prec in ('bulk', 'list'))) or (lu and hd.get('feedback-id')))
    au = hinfo.get('auth_full', {})
    al = hinfo.get('alignment', {})
    reqs = {
        'SPF passes': au.get('spf') == 'pass',
        'DKIM passes': al.get('dkim_pass', False),
        'DMARC record exists and passes (aligned)': au.get('dmarc') == 'pass',
        'One-click unsubscribe (RFC 8058)': 'one-click' in lup.lower(),
        'Unsubscribe link/header present': bool(lu),
    }
    node['bulk'] = {'is_bulk': bool(is_bulk), 'esp': esp, 'bcl': hinfo.get('bcl', ''), 'bcl_meaning': bcl_band(hinfo.get('bcl', '')),
                    'requirements': reqs, 'meets_sender_requirements': all(reqs.values())}
    signals['bulk'] = bool(is_bulk)
    node['signals'] = signals


# Never propose blocking these: shared infrastructure used by everyone (blocking would stop legitimate mail).
NEVER_BLOCK = {'google.com', 'gmail.com', 'googleusercontent.com', 'youtube.com', 'microsoft.com', 'office.com', 'office365.com',
               'outlook.com', 'live.com', 'hotmail.com', 'sharepoint.com', 'microsoftonline.com', 'onmicrosoft.com', 'bing.com',
               'linkedin.com', 'facebook.com', 'instagram.com', 'apple.com', 'icloud.com', 'amazon.com', 'amazonaws.com',
               'cloudfront.net', 'dropbox.com', 'docusign.net', 'docusign.com', 'adobe.com', 'yahoo.com', 'twitter.com', 'x.com',
               'sendgrid.net', 'mailchimp.com', 'zoom.us', 'whatsapp.com', 'github.com', 'cloudflare.com', 'akamaihd.net',
               'windows.net', 'azureedge.net', 'doubleclick.net', 'safelinks.protection.outlook.com', 'aka.ms', 'live.net'}


def block_domain(host: str) -> str:
    """The narrowest safe domain to block for a host, or '' if it must not be blocked."""
    h = (host or '').lower().strip('.')
    if not h:
        return ''
    for suf in ABUSED_HOSTING:
        if h == suf:
            return ''
        if h.endswith('.' + suf):
            return h  # shared hosting: block only this site, never the whole platform
    reg = registrable(h)
    if reg in NEVER_BLOCK or h in NEVER_BLOCK or reg in FREEMAIL:
        return ''
    return reg


# =========================================================================== decision builder
OUTCOMES = {
    'DELETE': {'title': 'DELETE AND BLOCK', 'color': 'red',
               'summary': 'This message is malicious or fraudulent. Do not release it.'},
    'VERIFY': {'title': 'KEEP QUARANTINED - VERIFY FIRST', 'color': 'amber',
               'summary': 'Not proven malicious, but there are warning signs. Release only if every check below is confirmed.'},
    'RELEASE': {'title': 'RELEASE AFTER QUICK CHECKS', 'color': 'green',
                'summary': 'No real threat indicators. Likely a false positive - confirm the checks and release.'},
    'BULK': {'title': 'BULK / MARKETING - USER\'S CHOICE', 'color': 'blue',
             'summary': 'Legitimate-looking bulk mail (newsletter / marketing). Not phishing. Release only if the user wants it.'},
    'RERUN': {'title': 'ANALYSIS INCOMPLETE - FIX AND RE-RUN', 'color': 'grey',
              'summary': 'Part of the message could not be inspected. Keep it quarantined until the analysis completes.'},
}

DEFENDER_STEPS = {
    'DELETE': [
        'Defender portal > Email & collaboration > Review > Quarantine: select the message > Delete messages (permanent).',
        'If the recipient asked for release: Deny the release request.',
        'Submissions > Emails > Submit to Microsoft > "Should have been blocked" and tick Block all emails from this sender/domain (Tenant Allow/Block List).',
        'Block the link domains and file hashes listed under "Block list" (Tenant Allow/Block List > URLs / Files).',
        'Find other copies: Explorer / Threat Explorer (Defender for Office 365) or Content search, filtered by sender and subject; remove them.',
        'If anyone already clicked, replied, called or entered a password: reset the password, revoke sessions, check MFA methods and inbox rules.',
    ],
    'VERIFY': [
        'Leave the message in quarantine.',
        'Contact the sender through a channel you already trust (phone number from your records, Teams) - never via details in this email.',
        'Ask the recipient whether they expected it.',
        'Answer the checks on the left. The recommendation updates: release only if every required check is "Yes".',
    ],
    'RELEASE': [
        'Quarantine: select the message > Release > Release to all recipients.',
        'Tick "Submit the message to Microsoft to improve detection" so it learns from the false positive.',
        'Only if you trust this sender long-term, also allow similar messages (creates a temporary Tenant Allow/Block List entry; default 30 days). Not available for malware/high-confidence phishing - use Submissions for those.',
        'Do NOT add the domain to anti-spam allowed lists or create mail-flow rules that bypass filtering (Microsoft secure-by-default ignores them for high-confidence threats).',
    ],
    'RELEASE_SPOOF': [
        'Quarantine: select the message > Release > Release to all recipients.',
        'Submissions > Emails > Submit to Microsoft > "Should not have been blocked", and turn on the option to allow emails with similar attributes. '
        'For a spoof detection this adds the sender + sending-infrastructure pair to Tenant Allow/Block List > Spoofed senders.',
        'Recurring sender? Add that domain pair yourself in Tenant Allow/Block List > Spoofed senders > Add (Allow, External) - see "Spoof allow pair" below. '
        'It allows only this sender from this infrastructure, not anyone using the domain.',
        'Do NOT add the whole domain to anti-spam allowed domains or create a mail-flow rule that bypasses filtering.',
        'Tell the sender (via their usual contact) that their SPF/DKIM/DMARC does not cover the service they send from, so they can fix it. Their domain is spoofable until they do.',
    ],
    'BULK': [
        'If the user wants it: Quarantine > Release to that user (or let them release it themselves).',
        'Prefer per-user decisions (the user\'s Safe Senders list) over organisation-wide allows for marketing mail.',
        'If many users want this sender, review the bulk threshold (BCL) in your anti-spam policy rather than allow-listing.',
        'If nobody wants it: delete it, or leave it to expire.',
    ],
    'RERUN': [
        'Fix the error shown (usually the download password, or a file too large to inspect) and click Analyze again.',
        'If it still cannot be analysed: keep it quarantined and treat it as suspicious.',
    ],
}


def build_decision(result: dict, rep: 'Report', cfg_partners: list | None = None) -> dict:
    if result.get('container', {}).get('requires_individual_review'):
        return {'outcome': 'RERUN', 'title': 'REVIEW EACH MESSAGE SEPARATELY', 'color': 'grey',
                'summary': 'Keep the messages quarantined until each has its own report.',
                'why': 'The package contains multiple messages. Sender and content decisions apply to one message at a time.',
                'confidence': 'n/a', 'message_type': 'Multiple messages', 'auth_only': False, 'spoof_pair': '',
                'microsoft_note': '', 'scorecard': [], 'checks': [], 'if_all_yes': '', 'if_any_no': '',
                'steps': {'RERUN': ['Download each message separately and run a review for each one.']},
                'iocs': {'sender': '', 'sender_domain': '', 'origin_ip': '', 'domains': [], 'urls': [], 'sha256': [], 'not_blocked': []},
                'disclaimer': ''}
    msgs = [m for m in result.get('messages', []) if m]
    top = msgs[0] if msgs else {}
    cat = (top.get('eop', {}) or {}).get('CAT', '').upper()
    sigs = top.get('signals', {}) if top else {}
    f = rep.findings
    def has(*codes):
        return any(x['code'] in codes for x in f)
    def worst(codes=None, sev=('high',)):
        return [x for x in f if x['severity'] in sev and (codes is None or x['code'] in codes)]
    sev_counts = {s: sum(1 for x in f if x['severity'] == s) for s in ('high', 'medium', 'low', 'info')}
    url_high = [u for u in rep.urls.values() if u['severity'] == 'high']
    attach_codes = {'RISKY_EXT', 'EXECUTABLE', 'MACROS', 'MACRO_CT', 'REMOTE_TEMPLATE', 'HTML_SMUGGLING', 'LNK', 'DISK_IMAGE',
                    'ONENOTE', 'CHM', 'SCRIPT', 'DOUBLE_EXT', 'RLO_NAME', 'TYPE_MISMATCH', 'PDF_LAUNCH', 'PDF_AUTO_JS',
                    'DDE', 'EQUATION', 'RTF_OBJECT', 'RTF_OBJUPDATE', 'CRED_FORM', 'SVG_ACTIVE', 'OBFUSCATED_SCRIPT',
                    'XLM', 'URL_SHORTCUT', 'INSTALLER', 'MIME_MISMATCH'}
    attachments = sum(int(m.get('attachment_count', 0)) for m in msgs)

    # ---- message type (what kind of attack / mail is this?)
    if worst(attach_codes):
        mtype = 'Malware / phishing attachment'
    elif has('BEC_PAYMENT', 'GIFT_CARD') and worst(('BEC_PAYMENT', 'GIFT_CARD', 'SECRECY')):
        mtype = 'Business email compromise (payment / gift-card fraud)'
    elif has('CALLBACK') and worst(('CALLBACK',)):
        mtype = 'Callback phishing (phone scam)'
    elif has('CRED_LURE', 'DOC_LURE', 'BRAND_LINK_MISMATCH', 'CRED_FORM', 'IMAGE_ONLY', 'QR_LURE') or url_high or worst(('LOOKALIKE_LINK',)):
        mtype = 'Credential phishing (link)'
    elif has('VIP_IMPERSONATION', 'DISPLAY_SPOOF', 'LOOKALIKE', 'HOMOGLYPH', 'BEC_OPENER', 'REPLYTO_FREEMAIL'):
        mtype = 'Impersonation / BEC attempt'
    elif sigs.get('bulk'):
        mtype = 'Bulk / marketing mail'
    elif cat in MS_SPAM:
        mtype = 'Ordinary message (Microsoft classed it as spam)'
    else:
        mtype = 'Ordinary message' if msgs else 'Archive'

    # ---- scorecard: five plain questions
    au = top.get('auth_full', {}) if top else {}
    al = top.get('alignment', {}) if top else {}
    def q(qid, question, status, answer, codes):
        ev = [f'[{x["severity"].upper()}] {x["title"]}' for x in f if x['code'] in codes and x['severity'] != 'info'][:5]
        return {'id': qid, 'question': question, 'status': status, 'answer': answer, 'evidence': ev}
    id_codes = {'DMARC_FAIL', 'COMPAUTH_FAIL', 'SPF_FAIL', 'DKIM_FAIL', 'DISPLAY_SPOOF', 'LOOKALIKE', 'HOMOGLYPH', 'VIP_IMPERSONATION',
                'BRAND_DISPLAY', 'DOMAIN_CONTAINS', 'IDN_SENDER', 'INTERNAL_SPOOF', 'REPLYTO_MISMATCH', 'REPLYTO_FREEMAIL', 'FREEMAIL_ROLE'}
    id_bad = [x for x in f if x['code'] in id_codes and x['severity'] in ('high', 'medium')]
    auth_codes = {'DMARC_FAIL', 'COMPAUTH_FAIL', 'SPF_FAIL', 'DKIM_FAIL'}
    imperson_high = [x for x in id_bad if x['severity'] == 'high' and x['code'] not in auth_codes]
    auth_only = bool(id_bad) and all(x['code'] in auth_codes for x in id_bad)
    if not top:
        sender = q('sender', 'Is the sender who they claim to be?', 'grey', 'No email headers (archive only).', id_codes)
    elif imperson_high:
        sender = q('sender', 'Is the sender who they claim to be?', 'red', 'No - impersonation signs (fake name, look-alike or spoofed identity).', id_codes)
    elif auth_only:
        sender = q('sender', 'Is the sender who they claim to be?', 'amber',
                   'Not proven - authentication fails. Often a sender misconfiguration, not an attack; confirm with the sender.', id_codes)
    elif id_bad:
        sender = q('sender', 'Is the sender who they claim to be?', 'amber', 'Unclear - authentication or identity is weak.', id_codes)
    elif al.get('aligned') and au.get('dmarc') in ('pass', 'bestguesspass', ''):
        sender = q('sender', 'Is the sender who they claim to be?', 'green',
                   f'Yes - {"DKIM" if al.get("dkim_aligned") else "SPF"} authenticates {top.get("from_domain", "")} (aligned).', id_codes)
    else:
        sender = q('sender', 'Is the sender who they claim to be?', 'amber', 'Not proven - no aligned SPF/DKIM pass in this copy.', id_codes)

    att_bad = worst(attach_codes, ('high', 'medium'))
    if any(x['severity'] == 'high' for x in att_bad):
        attq = q('files', 'Are the attachments dangerous?', 'red', 'Yes - dangerous file content found.', attach_codes)
    elif not result.get('complete', True):
        attq = q('files', 'Are the attachments dangerous?', 'amber', 'Unknown. Part of the input could not be inspected.', attach_codes)
    elif not attachments and not result.get('other'):
        attq = q('files', 'Are the attachments dangerous?', 'green', 'No attachments.', attach_codes)
    elif att_bad or has('ENCRYPTED_ARCHIVE', 'UNINSPECTED_ARCHIVE', 'HTML_ATTACHMENT'):
        attq = q('files', 'Are the attachments dangerous?', 'amber', 'Possibly - risky format or contents could not be fully seen.',
                 attach_codes | {'ENCRYPTED_ARCHIVE', 'UNINSPECTED_ARCHIVE', 'HTML_ATTACHMENT'})
    else:
        attq = q('files', 'Are the attachments dangerous?', 'green', f'No dangerous content found in {attachments} attachment(s).', attach_codes)

    link_codes = {'CRED_LURE', 'DOC_LURE', 'BRAND_LINK_MISMATCH', 'REDIRECT_ABUSE', 'EXTERNAL_TENANT', 'IMAGE_ONLY', 'QR_LURE', 'LOOKALIKE_LINK'}
    url_med = [u for u in rep.urls.values() if u['severity'] == 'medium']
    if not rep.urls:
        linkq = q('links', 'Do the links lead somewhere dangerous?', 'green', 'No links.', link_codes)
    elif url_high or worst(link_codes):
        linkq = q('links', 'Do the links lead somewhere dangerous?', 'red', f'Yes - {len(url_high) or "some"} link(s) are deceptive or high-risk.', link_codes)
    elif url_med or worst(link_codes, ('medium',)):
        linkq = q('links', 'Do the links lead somewhere dangerous?', 'amber', f'{len(url_med)} link(s) look suspicious - see Links tab.', link_codes)
    else:
        linkq = q('links', 'Do the links lead somewhere dangerous?', 'green', f'No warning signs on {len(rep.urls)} link(s).', link_codes)

    trick_codes = {'BEC_PAYMENT', 'GIFT_CARD', 'SECRECY', 'BEC_OPENER', 'CALLBACK', 'CRED_LURE', 'DOC_LURE', 'QR_LURE', 'LURE_SUBJECT', 'URGENCY'}
    tb = worst(trick_codes, ('high', 'medium'))
    if any(x['severity'] == 'high' for x in tb):
        trickq = q('ask', 'Does it try to trick someone into acting?', 'red', 'Yes - ' + mtype.lower() + ' pattern.', trick_codes)
    elif tb:
        trickq = q('ask', 'Does it try to trick someone into acting?', 'amber', 'Possibly - pressure or payment wording found.', trick_codes)
    else:
        trickq = q('ask', 'Does it try to trick someone into acting?', 'green', 'No manipulation patterns found.', trick_codes)

    ms_label = top.get('eop_category', '') if top else ''
    if cat in MS_MALWARE | MS_HIGH_PHISH:
        msq = {'id': 'microsoft', 'question': 'What did Microsoft decide?', 'status': 'red', 'answer': f'{ms_label} - one of Microsoft\'s strongest verdicts.', 'evidence': []}
    elif cat in MS_PHISH:
        msq = {'id': 'microsoft', 'question': 'What did Microsoft decide?', 'status': 'amber', 'answer': f'{ms_label}.', 'evidence': []}
    elif cat in MS_SPAM | MS_BULK or cat == 'FTBP':
        msq = {'id': 'microsoft', 'question': 'What did Microsoft decide?', 'status': 'blue', 'answer': f'{ms_label} (not a phishing/malware verdict).', 'evidence': []}
    else:
        msq = {'id': 'microsoft', 'question': 'What did Microsoft decide?', 'status': 'grey', 'answer': 'No Microsoft verdict in this copy.' if not cat else ms_label, 'evidence': []}
    if top and top.get('sfty'):
        msq['evidence'] = [f'Safety tip {k}: {v}' for k, v in top['sfty'].items()]
    if top and top.get('compauth_meaning'):
        msq['evidence'].append(f'compauth {au.get("compauth", "")} reason {au.get("reason", "")}: {top["compauth_meaning"]}')
    scorecard = [sender, attq, linkq, trickq, msq]

    # ---- outcome
    reds = sum(1 for s in scorecard[:4] if s['status'] == 'red')
    ambers = sum(1 for s in scorecard[:4] if s['status'] == 'amber')
    bulk = (top.get('bulk') or {}) if top else {}
    partner = bool(top) and registrable(top.get('from_domain', '')) in {registrable(d) for d in (cfg_partners or [])}
    if not result.get('complete', True):
        outcome, confidence, why = 'RERUN', 'n/a', 'The analysis did not finish, so there is nothing reliable to decide on yet.'
    elif reds:
        outcome = 'DELETE'
        agree = cat in MS_MALWARE | MS_HIGH_PHISH | MS_PHISH
        confidence = 'High' if (reds >= 2 or agree) else 'Medium'
        why = (f'{reds} of 4 independent checks are red' + (' and Microsoft agrees' if agree else '') + '.')
    elif ambers >= 3 and (cat in MS_PHISH | MS_HIGH_PHISH or '9.25' in (top.get('sfty') or {})):
        outcome, confidence = 'DELETE', 'High' if cat in MS_PHISH | MS_HIGH_PHISH else 'Medium'
        why = (f'{ambers} of 4 independent checks are amber at the same time' +
               (', and Microsoft also classed it as phishing.' if cat in MS_PHISH | MS_HIGH_PHISH else ', from a first-time sender.') +
               ' Several weak signals together are a strong one.')
    elif cat in MS_MALWARE:
        outcome, confidence = 'DELETE', 'High'
        why = 'Microsoft detected malware. This offline review cannot rule that out, so treat it as malicious.'
    elif cat in MS_HIGH_PHISH or ambers:
        outcome = 'VERIFY'
        if cat in MS_HIGH_PHISH and not ambers:
            confidence = 'Medium'
            why = ('Microsoft says high-confidence phishing, but this review found no independent evidence. Microsoft sees URL/IP '
                   'reputation and campaign data that this offline tool cannot. Possible false positive - verify before acting.')
        elif auth_only and ambers == 1 and sender['status'] == 'amber':
            confidence = 'Medium'
            why = ('Only the sender authentication fails; the content, links and attachments show no attack. This is the classic '
                   'pattern of a legitimate sender whose SPF/DKIM/DMARC is not set up for the service they send from. '
                   'Confirm with the sender, then release and report it as a false positive.')
        else:
            confidence = 'Medium'
            why = f'{ambers} check(s) are amber: not proof of an attack, but not safe to release unverified.'
        if partner and al.get('aligned'):
            why += ' The sender is one of your listed partners and is authenticated - but partner mailboxes get compromised, so still confirm.'
    elif bulk.get('is_bulk'):
        outcome = 'BULK'
        confidence = 'High' if bulk.get('meets_sender_requirements') or al.get('aligned') else 'Medium'
        why = 'Bulk sender, authenticated, and no phishing or malware indicators.' if al.get('aligned') else 'Bulk mail with no threat indicators (authentication is incomplete).'
    else:
        outcome = 'RELEASE'
        green_sender = sender['status'] == 'green'
        confidence = 'High' if green_sender and cat not in MS_PHISH else 'Medium'
        why = ('All four independent checks are green' + (' and the sender is authenticated.' if green_sender else
                                                          '; sender authentication is not proven, so confirm the checks.'))

    # ---- human checks: only what the tool cannot know
    checks = []
    def chk(cid, text, required=True):
        checks.append({'id': cid, 'text': text, 'required': required})
    if outcome in ('VERIFY', 'RELEASE', 'BULK'):
        if outcome == 'BULK':
            chk('wanted', 'The recipient actually wants this newsletter / marketing mail.')
        else:
            chk('expected', 'The recipient was expecting this message (ask them).')
            chk('known', 'The sender is a known contact or an existing business relationship.')
            if sender['status'] != 'green' or outcome == 'VERIFY' or sigs.get('payment') or has('BEC_PAYMENT', 'FREEMAIL_ROLE'):
                chk('callback', 'You confirmed it with the sender using contact details you ALREADY had (not from this email).')
            if rep.urls:
                hosts = sorted({registrable(u['host']) for u in rep.urls.values() if u.get('host')})[:5]
                chk('links', 'The link domains are ones this sender normally uses: ' + (', '.join(hosts) or '-'))
            if attachments:
                chk('files', 'The attachment type is what this sender normally sends.')
            if sigs.get('payment') or has('BEC_PAYMENT'):
                chk('payment', 'Any payment or bank-detail change was confirmed by phone with a known contact.')
    def wrapper(u):
        fl = ' '.join(u.get('flags', []))
        return 'trusted-site redirect' in fl or 'security link wrapper' in fl
    bad_urls = [u for u in rep.urls.values() if u['severity'] in ('high', 'medium') and not wrapper(u)]
    sdom = block_domain(top.get('from_domain', '')) if top else ''
    iocs = {'sender': top.get('from_address', '') if top and outcome in ('DELETE', 'VERIFY') else '',
            'sender_domain': sdom if outcome in ('DELETE', 'VERIFY') else '',
            'urls': [u['defanged'] for u in bad_urls][:15],
            'domains': sorted({d for d in (block_domain(u.get('host', '')) for u in bad_urls) if d})[:15],
            'sha256': [], 'origin_ip': top.get('origin_ip', '') if top else '',
            'not_blocked': sorted({u.get('host', '') for u in rep.urls.values() if u['severity'] in ('high', 'medium') and u.get('host') and not block_domain(u['host'])})[:10]}
    def walk(n):
        if n.get('hashes') and n.get('kind') not in ('message', 'dir') and any(x['where'] == n.get('where') and x['severity'] in ('high', 'medium') for x in f):
            iocs['sha256'].append(f'{n["hashes"]["sha256"]}  {n.get("name", "")}')
        for c in n.get('children', []) or []:
            walk(c)
    for m in msgs:
        walk(m)
    if result.get('other'):
        walk(result['other'])
    ms_note = ''
    if cat:
        independent = 'red' if reds else ('amber' if ambers else 'green')
        if cat in MS_MALWARE | MS_HIGH_PHISH | MS_PHISH and independent == 'green':
            ms_note = 'Microsoft and this review DISAGREE (Microsoft: threat, review: clean). Verify carefully - see checks.'
        elif cat in MS_MALWARE | MS_HIGH_PHISH | MS_PHISH and independent == 'red':
            ms_note = 'Microsoft and this review AGREE: malicious.'
        elif cat in MS_SPAM | MS_BULK and independent == 'red':
            ms_note = 'This review found MORE than Microsoft did (Microsoft: spam/bulk, review: threat). Treat as malicious.'
    eop = (top.get('eop') or {}) if top else {}
    infra = ''
    ptr = (eop.get('PTR') or '').strip().lower()
    if ptr and ptr not in ('infonorecords', 'infodomainnonexistent', 'infonxdomain'):
        infra = registrable(ptr)
    elif re.fullmatch(r'\d+\.\d+\.\d+\.\d+', eop.get('CIP', '') or ''):
        infra = '.'.join(eop['CIP'].split('.')[:3]) + '.0/24'
    spoof_pair = f"{top.get('from_domain', '')}, {infra}" if (top and infra and auth_only and outcome == 'VERIFY') else ''
    o = OUTCOMES[outcome]
    return {'outcome': outcome, 'auth_only': bool(auth_only and outcome == 'VERIFY'), 'spoof_pair': spoof_pair, 'title': o['title'], 'color': o['color'], 'summary': o['summary'], 'confidence': confidence,
            'why': why, 'message_type': mtype, 'microsoft_note': ms_note, 'scorecard': scorecard, 'checks': checks,
            'if_all_yes': ('Release, submit as a false positive and allow only the spoofed-sender pair.' if (auth_only and outcome == 'VERIFY') else
                           'Release - and submit to Microsoft as a false positive.') if outcome in ('VERIFY', 'RELEASE') else
                          ('Release to that user.' if outcome == 'BULK' else ''),
            'if_any_no': 'Do not release. Delete and block (see steps).' if outcome in ('VERIFY', 'RELEASE') else
                         ('Leave it in quarantine or delete it.' if outcome == 'BULK' else ''),
            'steps': DEFENDER_STEPS, 'iocs': iocs,
            'disclaimer': 'Confidence reflects how strongly the offline evidence and Microsoft\'s verdict agree. No static review is 100% - your checks close the gap.'}


# =========================================================================== top level
def assess(rep: Report) -> dict:
    counts = {s: 0 for s in ('high', 'medium', 'low', 'info')}
    for f in rep.findings:
        counts[f['severity']] += 1
    url_high = sum(1 for u in rep.urls.values() if u['severity'] == 'high')
    url_med = sum(1 for u in rep.urls.values() if u['severity'] == 'medium')
    if not rep.complete:
        level, headline = 'INCOMPLETE', 'Review incomplete - keep the message quarantined.'
        advice = 'Part of the message could not be inspected (see errors). Fix the cause (password, size limit) and run again, or escalate.'
    elif counts['high'] or url_high:
        level, headline = 'HIGH RISK', 'Strong malicious indicators - do NOT release.'
        advice = 'Keep quarantined or delete. Block the sender/domain/URLs if appropriate and check whether similar messages reached other mailboxes (Threat Explorer / Content search).'
    elif counts['medium'] or url_med:
        level, headline = 'SUSPICIOUS', 'Suspicious indicators - verify before any release.'
        advice = 'Confirm with the sender through a known channel (phone/Teams - not by replying). Release only if the business reason and the attachment are confirmed.'
    else:
        level, headline = 'NO STRONG INDICATORS', 'No strong indicators found - this is NOT a safe verdict.'
        advice = 'Still verify the sender and business context. Static checks cannot see zero-day exploits, QR images or links that turn malicious later.'
    return {'level': level, 'headline': headline, 'advice': advice, 'counts': counts,
            'suspicious_links': url_high + url_med}


def inspect_input(path: Path, secrets: dict, progress: Progress, config: dict | None = None) -> dict:
    rep = Report()
    budget = Budget()
    size = path.stat().st_size
    if size > MAX_SOURCE:
        raise ReviewError(f'Input is {size_fmt(size)}; limit is {size_fmt(MAX_SOURCE)}.')
    progress('Reading input file...')
    data = path.read_bytes()
    user_pw = [p for p in secrets.get('attachment_passwords', []) if p]
    outer_pwd = secrets.get('zip_password', '')
    supplied = set(user_pw + ([outer_pwd] if outer_pwd else []))
    ctx = {'user_passwords': user_pw, 'supplied_passwords': supplied, 'report_passwords': supplied.copy(),
           'candidates': list(user_pw), 'unlocked': [], 'recipients': [], 'config': config or {}}
    result = {'tool': 'Quarantine Review Assistant', 'version': VERSION,
              'generated_utc': _dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ'),
              'input': {'name': safe(path.name, 260), 'size': size, 'hashes': hashes(data)},
              'container': {}, 'messages': [], 'other': None}
    kind, desc = identify(data)
    result['input']['signature'] = desc
    if path.suffix.lower() == '.eml' or kind == 'eml':
        result['container'] = {'kind': 'eml'}
        progress('Parsing message...')
        result['messages'].append(inspect_message(rep, data, budget, ctx, 'Message 1'))
    elif kind == 'zip':
        zf = open_zip(data)
        with zf:
            infos = [i for i in zf.infolist() if not i.is_dir()]
            encs = sorted({zip_encryption(i) for i in infos})
            result['container'] = {'kind': 'zip', 'entries': len(infos), 'encryption': ', '.join(encs)}
            outer_cands = list(dict.fromkeys(([outer_pwd] if outer_pwd else []) + user_pw))
            guidish = re.compile(r'^[0-9a-f]{8}-[0-9a-f-]{20,}(\.eml)?$', re.I)
            named_messages = {i for i in infos if i.filename.lower().endswith('.eml') or guidish.match(i.filename.split('/')[-1])}
            quarantine_like = bool(named_messages) or (len(infos) == 1 and not ext_of(infos[0].filename))
            result['container']['looks_like_quarantine_package'] = bool(quarantine_like)
            msg_entries, others = [], []
            identified = set(named_messages)
            locked = False
            progress('Opening quarantine package...')
            entries_to_identify = [] if len(named_messages) >= 2 else infos
            for info in entries_to_identify:
                try:
                    content, _ = read_zip_entry(zf, info, budget, outer_cands or None, MAX_EML)
                except PasswordError as exc:
                    locked = True
                    if quarantine_like:
                        if not outer_pwd:
                            hint = ' Enter the password you chose in the Defender portal "Download message" dialog.'
                        else:
                            hint = (' Check Caps Lock / keyboard layout and that this is the password typed in the Defender '
                                    '"Download message" dialog (not your account password). If unsure, download the message again with a new password.')
                        rep.fail(f'Quarantine package: {exc}{hint}')
                        result['container']['password_status'] = 'wrong' if outer_pwd else 'missing'
                    else:
                        rep.fail(f'{safe(info.filename, 120)}: {exc}')
                    continue
                except ReviewError as exc:
                    rep.fail(f'{safe(info.filename, 120)}: {exc}')
                    continue
                if info.flag_bits & 1:
                    result['container']['password_status'] = 'ok'
                if looks_like_email(content) or info.filename.lower().endswith('.eml'):
                    identified.add(info)
                    msg_entries.append((info, content))
                else:
                    identified.discard(info)
                    others.append(info)
            multiple = len(identified) > 1
            result['container']['messages'] = len(identified) if multiple else len(msg_entries)
            if multiple:
                result['container']['requires_individual_review'] = True
                rep.fail('Multiple messages in this package. Download and review each message separately.')
            elif msg_entries:
                for other in others:
                    rep.fail(f'{safe(other.filename, 120)}: Additional package entry was not inspected alongside the message.')
                info, content = msg_entries[0]
                progress('Analysing message...')
                try:
                    m = inspect_message(rep, content, budget, ctx, 'Message 1')
                    m['entry'] = safe(info.filename, 200)
                    result['messages'].append(m)
                except ReviewError as exc:
                    rep.fail(f'Message 1: {exc}')
            elif rep.complete or (locked and not quarantine_like):
                # Not a quarantine package - treat as a stand-alone archive (e.g. an extracted attachment).
                result['container']['kind'] = 'archive'
                root = new_node(path.name)
                root['where'] = path.name
                rep.add('info', 'NOT_QUARANTINE', 'No email found in this ZIP', 'Reviewed as a stand-alone archive.', path.name)
                progress('Inspecting archive...')
                ctx['candidates'] = outer_cands
                ctx['is_attachment_chain'] = False
                walk_zip(rep, root, zf, path.name, budget, ctx, 1)
                root['hashes'] = result['input']['hashes']
                root['size'] = size
                root['kind'] = 'zip'
                root['signature'] = 'ZIP container'
                result['other'] = root
    else:
        raise ReviewError(f'Unsupported input ({desc or "unknown format"}). Select a quarantine .zip or an .eml file.')

    progress('Building report...')
    result['findings'] = sorted(rep.findings, key=lambda f: -SEV_ORDER[f['severity']])
    result['urls'] = sorted(rep.urls.values(), key=lambda u: -SEV_ORDER[u['severity']])
    result['errors'] = rep.errors
    result['complete'] = rep.complete
    result['unlocked'] = ctx.get('unlocked', [])
    result['assessment'] = assess(rep)
    result['decision'] = build_decision(result, rep, (config or {}).get('trusted_partner_domains', []))
    redact_report_passwords(result, ctx['report_passwords'])
    return result


# =========================================================================== text rendering
def render_text(r: dict) -> str:
    L = []
    w = L.append
    a = r.get('assessment', {})
    w('QUARANTINE REVIEW ASSISTANT v' + r.get('version', '') + ' | OFFLINE METADATA REPORT')
    w('=' * 78)
    w(f"Generated (UTC): {r.get('generated_utc', '')}")
    w(f"Input          : {r['input']['name']}  ({size_fmt(r['input']['size'])})")
    w(f"Input SHA256   : {r['input']['hashes']['sha256']}")
    c = r.get('container', {})
    if c:
        w(f"Container      : {c.get('kind', '')}  entries={c.get('entries', '-')}  encryption={c.get('encryption', '-')}  messages={c.get('messages', '-')}")
    d = r.get('decision') or {}
    if d:
        dots = {'red': 'X', 'amber': '!', 'green': 'OK', 'blue': 'i', 'grey': '-'}
        w('')
        w('#' * 78)
        w(f"  DECISION: {d.get('title', '')}")
        w(f"  Confidence: {d.get('confidence', '')}  |  Type: {d.get('message_type', '')}")
        w(f"  {d.get('summary', '')}")
        w(f"  Why: {d.get('why', '')}")
        if d.get('microsoft_note'):
            w(f"  Microsoft: {d['microsoft_note']}")
        w('#' * 78)
        w('')
        w('SCORECARD')
        for sc in d.get('scorecard', []):
            w(f"  [{dots.get(sc['status'], '?'):>2}] {sc['question']:<44} {sc['answer']}")
            for ev in sc.get('evidence', [])[:4]:
                w(f"         - {ev}")
        if d.get('checks'):
            w('')
            w('CONFIRM BEFORE RELEASING (answer each one)')
            for c in d['checks']:
                w(f"  [ ] {c['text']}")
            w(f"  All yes  -> {d.get('if_all_yes', '')}")
            w(f"  Any no   -> {d.get('if_any_no', '')}")
        w('')
        w('WHAT TO DO IN DEFENDER')
        for i, step in enumerate(d.get('steps', {}).get(d.get('outcome', ''), []), 1):
            w(f"  {i}. {step}")
        if d.get('spoof_pair'):
            w('')
            w(f"SPOOF ALLOW PAIR (only after you confirm the sender): {d['spoof_pair']}")
            w('  Tenant Allow/Block List > Spoofed senders > Add > Allow, External. Format: <spoofed domain>, <sending infrastructure>.')
        io = d.get('iocs', {})
        if any(io.get(k) for k in ('sender', 'sender_domain', 'urls', 'domains', 'sha256')):
            w('')
            w('BLOCK LIST (for Tenant Allow/Block List - only if you decide to block)')
            if io.get('sender'):
                w(f"  Sender  : {io['sender']}")
            if io.get('sender_domain'):
                w(f"  Domain  : {io['sender_domain']}")
            for x in io.get('domains', []):
                w(f"  Link dom: {x}")
            for x in io.get('urls', []):
                w(f"  URL     : {x}")
            for x in io.get('sha256', []):
                w(f"  SHA256  : {x}")
            for x in io.get('not_blocked', []):
                w(f"  (not blocked - shared service: {x})")
        w('')
        w(d.get('disclaimer', ''))
    w('')
    w(f"TECHNICAL ASSESSMENT: {a.get('level', '')} - {a.get('headline', '')}")
    w(f"  {a.get('advice', '')}")
    cnt = a.get('counts', {})
    w(f"  Findings: high={cnt.get('high', 0)} medium={cnt.get('medium', 0)} low={cnt.get('low', 0)} info={cnt.get('info', 0)}  suspicious links={a.get('suspicious_links', 0)}")
    if r.get('errors'):
        w('')
        w('ERRORS (review incomplete):')
        for e in r['errors']:
            w(f'  ! {e}')
    if r.get('findings'):
        w('')
        w('FINDINGS')
        w('-' * 78)
        for f in r['findings']:
            w(f"  [{f['severity'].upper():6}] {f['title']}" + (f"   (ATT&CK {f['attack']})" if f.get('attack') else ''))
            if f['detail']:
                w(f"           {f['detail']}")
            if f['where']:
                w(f"           at: {f['where']}")

    def tree(node, indent=1):
        pad = '  ' * indent
        if node.get('kind') == 'message':
            w(f"{pad}MESSAGE  {node.get('where', '')}")
            hd = node.get('headers', {})
            for k in ('From', 'Reply-To', 'Return-Path', 'To', 'Subject', 'Date', 'Message-ID'):
                if k in hd:
                    w(f'{pad}  {k:12}: {hd[k][:200]}')
            au = node.get('auth', {})
            if au:
                w(f"{pad}  Auth        : SPF={au.get('spf', '-')} DKIM={au.get('dkim', '-')} DMARC={au.get('dmarc', '-')} compauth={au.get('compauth', '-')}")
            if node.get('eop_category'):
                w(f"{pad}  EOP verdict : {node['eop_category']}  SFV={node.get('eop', {}).get('SFV', '-')}  SCL={node.get('eop', {}).get('SCL', '-')}")
            if node.get('origin_ip'):
                w(f"{pad}  Origin IP   : {node['origin_ip']}  ({len(node.get('received', []))} Received hops)")
            w(f"{pad}  SHA256      : {node['hashes']['sha256']}")
            if node.get('password_hint_count'):
                w(f"{pad}  Attachment password candidates found in body: {node['password_hint_count']}")
            w(f"{pad}  Attachments : {node.get('attachment_count', 0)}")
        else:
            label = node.get('name', '')
            meta = []
            if node.get('size') is not None:
                meta.append(size_fmt(node['size']))
            if node.get('signature'):
                meta.append(node['signature'])
            if node.get('encryption') and node['encryption'] != 'none':
                meta.append('encrypted:' + node['encryption'])
            w(f"{pad}- {label}  [{' | '.join(meta)}]")
            if node.get('hashes'):
                w(f"{pad}    SHA256: {node['hashes']['sha256']}")
            if node.get('tags'):
                w(f"{pad}    Tags  : {', '.join(node['tags'])}")
            if node.get('note'):
                w(f"{pad}    Note  : {node['note']}")
        for ch in node.get('children', []):
            tree(ch, indent + 2)

    w('')
    w('STRUCTURE (message > attachment > archive entries)')
    w('-' * 78)
    for m in r.get('messages', []):
        tree(m)
        if m.get('body_preview'):
            w('    Body preview (text only, first lines):')
            for line in m['body_preview'].splitlines()[:15]:
                w('      | ' + line[:150])
    if r.get('other'):
        tree(r['other'])
    if r.get('urls'):
        w('')
        w('LINKS (defanged)')
        w('-' * 78)
        for u in r['urls']:
            w(f"  [{u['severity'].upper():6}] {u['defanged'][:200]}")
            if u['flags']:
                w(f"           {'; '.join(u['flags'])}")
            w(f"           from: {', '.join(u['sources'])[:200]}")
    w('')
    w('=' * 78)
    w('THIS IS NOT A CLEAN/SAFE VERDICT. Nothing was executed, rendered or extracted to disk.')
    w('Unexpected scripts, executables, encryption, look-alike domains or parse errors = keep quarantined.')
    return '\n'.join(L) + '\n'


# =========================================================================== CLI
def main(argv=None):
    ap = argparse.ArgumentParser(description='Offline, metadata-only review of quarantined email (Windows Sandbox).')
    ap.add_argument('--input', '-i', required=True, help='Quarantine download .zip or .eml')
    ap.add_argument('--password-stdin', action='store_true', help='Read the quarantine ZIP password from stdin (first line)')
    ap.add_argument('--secrets-stdin', action='store_true', help='Read one JSON line {"zip_password":..,"attachment_passwords":[..]} from stdin')
    ap.add_argument('--json-out', help='Write the structured JSON report here')
    ap.add_argument('--text-out', help='Write the text report here (default: stdout)')
    ap.add_argument('--progress-file', help='File updated with progress messages (for the GUI)')
    ap.add_argument('--config', help='organization.json: your domains, VIP names, M365 tenant names, partner domains')
    args = ap.parse_args(argv)

    secrets = {'zip_password': '', 'attachment_passwords': []}
    try:
        if args.secrets_stdin:
            line = sys.stdin.buffer.readline().decode('utf-8-sig', errors='replace').strip()
            if line:
                loaded = json.loads(line)
                secrets['zip_password'] = str(loaded.get('zip_password') or '')
                ap_list = loaded.get('attachment_passwords') or []
                if isinstance(ap_list, str):
                    ap_list = [ap_list]
                secrets['attachment_passwords'] = [str(p) for p in ap_list if str(p).strip()][:MAX_PASSWORD_CANDIDATES]
        elif args.password_stdin:
            secrets['zip_password'] = sys.stdin.readline().rstrip('\r\n')
    except (ValueError, OSError) as exc:
        print(f'ERROR: could not read secrets from stdin: {safe(exc)}')
        return 2

    progress = Progress(args.progress_file)
    try:
        path = Path(args.input)
        if not path.is_file():
            raise ReviewError(f'Cannot find file: {safe(path)}')
        config = {}
        if args.config and Path(args.config).is_file():
            try:
                config = json.loads(Path(args.config).read_text(encoding='utf-8-sig'))
            except (ValueError, OSError):
                config = {}
        result = inspect_input(path, secrets, progress, config)
        code = 0 if result['complete'] else 3
    except (ReviewError, OSError, MemoryError, ValueError, EOFError, RecursionError) as exc:
        result = {'tool': 'Quarantine Review Assistant', 'version': VERSION,
                  'generated_utc': _dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ'),
                  'input': {'name': safe(args.input, 260), 'size': 0, 'hashes': {'sha256': '', 'sha1': '', 'md5': ''}},
                  'container': {}, 'messages': [], 'other': None, 'findings': [], 'urls': [],
                  'errors': [safe(exc, 600)], 'complete': False, 'unlocked': []}
        result['assessment'] = {'level': 'INCOMPLETE', 'headline': 'Review failed - keep the message quarantined.',
                                'advice': 'The input could not be processed. This is not evidence that the email is safe.',
                                'counts': {'high': 0, 'medium': 0, 'low': 0, 'info': 0}, 'suspicious_links': 0}
        result['decision'] = build_decision(result, Report())
        redact_report_passwords(result, [secrets['zip_password'], *secrets['attachment_passwords']])
        code = 2
    text = render_text(result)
    if args.json_out:
        with open(args.json_out, 'w', encoding='utf-8') as fh:
            json.dump(result, fh, ensure_ascii=True, separators=(',', ':'))
    if args.text_out:
        with open(args.text_out, 'w', encoding='utf-8') as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    progress('Done.')
    return code


if __name__ == '__main__':
    sys.exit(main())
