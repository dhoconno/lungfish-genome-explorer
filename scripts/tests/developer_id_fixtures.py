"""Synthetic Developer ID certificates and keychain listings for release tests.

The certificates are hand-built DER with the subject, issuer and validity a release checks and a dummy key and
signature. No key pair is created and no keychain is read or changed.
"""
from __future__ import annotations

import base64
from datetime import datetime
import hashlib

TEAM = "TEAM123456"
NAME = f"Developer ID Application: Example Corp ({TEAM})"
G1 = ("Developer ID Certification Authority", "Apple Certification Authority")
G2 = ("Developer ID Certification Authority", "G2")
_OIDS = {"CN": "550403", "OU": "55040b", "O": "55040a", "C": "550406", "UID": "0992268993f22c640101"}


def _tlv(tag: int, value: bytes) -> bytes:
    length = len(value)
    if length < 0x80:
        return bytes([tag, length]) + value
    body = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([tag, 0x80 | len(body)]) + body + value


def _name(pairs: list[tuple[str, str]]) -> bytes:
    return _tlv(0x30, b"".join(
        _tlv(0x31, _tlv(0x30, _tlv(0x06, bytes.fromhex(_OIDS[key]))
                        + _tlv(0x13 if key == "C" else 0x0C, value.encode())))
        for key, value in pairs))


def _time(moment: datetime) -> bytes:
    if moment.year < 2050:
        return _tlv(0x17, moment.strftime("%y%m%d%H%M%SZ").encode())
    return _tlv(0x18, moment.strftime("%Y%m%d%H%M%SZ").encode())


def certificate_der(name: str = NAME, team: str = TEAM, *, issuer: tuple[str, str] = G2,
                    not_before: datetime, not_after: datetime, serial: int = 1) -> bytes:
    algorithm = _tlv(0x30, _tlv(0x06, bytes.fromhex("2a864886f70d01010b")) + b"\x05\x00")
    issuer_cn, issuer_ou = issuer
    tbs = _tlv(0x30, _tlv(0xA0, _tlv(0x02, b"\x02")) + _tlv(0x02, serial.to_bytes(4, "big")) + algorithm
               + _name([("CN", issuer_cn), ("OU", issuer_ou), ("O", "Apple Inc."), ("C", "US")])
               + _tlv(0x30, _time(not_before) + _time(not_after))
               + _name([("UID", team), ("CN", name), ("OU", team), ("O", "Example Corp"), ("C", "US")])
               + _tlv(0x30, algorithm + _tlv(0x03, b"\x00" + bytes(16))))
    return _tlv(0x30, tbs + algorithm + _tlv(0x03, b"\x00" + bytes(16)))


def sha1(der: bytes) -> str:
    return hashlib.sha1(der).hexdigest().upper()


def pem(der: bytes) -> str:
    body = base64.b64encode(der).decode()
    return ("-----BEGIN CERTIFICATE-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
            + "\n-----END CERTIFICATE-----\n")


def find_identity_output(rows: list[tuple[str, str, str | None]]) -> str:
    """`security find-identity -p codesigning` for rows of (SHA-1, name, trust problem or None)."""
    valid = [(digest, name) for digest, name, problem in rows if problem is None]
    lines = ["Policy: Code Signing", "  Matching identities"]
    lines += [f'  {index}) {digest} "{name}"' + (f" ({problem})" if problem else "")
              for index, (digest, name, problem) in enumerate(rows, 1)]
    lines += [f"     {len(rows)} identities found", "", "  Valid identities only"]
    lines += [f'  {index}) {digest} "{name}"' for index, (digest, name) in enumerate(valid, 1)]
    lines.append(f"     {len(valid)} valid identities found")
    return "\n".join(lines) + "\n"
