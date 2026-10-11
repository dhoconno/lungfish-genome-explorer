"""Developer ID selection, expiry and throwaway verification with fake security, codesign and spctl output."""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import importlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.tests.developer_id_fixtures import (G1, G2, NAME, TEAM, certificate_der, find_identity_output, pem,
                                                 sha1)

NOW = datetime(2026, 10, 11, 12, 0, 0, tzinfo=timezone.utc)


def make(*, issuer=G2, issued=NOW - timedelta(days=30), lasts=timedelta(days=365), name=NAME, serial=1):
    der = certificate_der(name, TEAM, issuer=issuer, not_before=issued, not_after=issued + lasts, serial=serial)
    return der, sha1(der)


class DeveloperIDTestCase(unittest.TestCase):
    def setUp(self):
        self.m = importlib.import_module("scripts.release.developer_id")
        # The installed one today: the original Sub-CA caps its expiry at its own.
        self.old_der, self.old = make(issuer=G1, issued=datetime(2026, 2, 4, 21, 3, 3, tzinfo=timezone.utc),
                                      lasts=datetime(2027, 2, 1, 22, 12, 15, tzinfo=timezone.utc)
                                      - datetime(2026, 2, 4, 21, 3, 3, tzinfo=timezone.utc))
        self.new_der, self.new = make(issuer=G2, issued=NOW - timedelta(days=1), serial=2)

    def keychain(self, rows, ders):
        identities = self.m.parse_identities(find_identity_output(rows))
        certificates = self.m.parse_certificates("".join(pem(der) for der in ders))
        return identities, certificates


class ParsingTests(DeveloperIDTestCase):
    def test_find_identity_marks_valid_rows_from_the_valid_section(self):
        text = find_identity_output([(self.old, NAME, None), (self.new, NAME, "CSSMERR_TP_NOT_TRUSTED")])
        identities = {identity.sha1: identity for identity in self.m.parse_identities(text)}
        self.assertEqual(set(identities), {self.old, self.new})
        self.assertTrue(identities[self.old].valid)
        self.assertFalse(identities[self.new].valid)
        self.assertEqual(identities[self.new].problem, "CSSMERR_TP_NOT_TRUSTED")
        self.assertEqual(identities[self.new].name, NAME)

    def test_valid_only_listing_and_lowercase_sha1_are_read(self):
        text = f'  1) {self.old.lower()} "{NAME}"\n     1 valid identities found\n  2) ABCDEF "short"\n'
        identities = self.m.parse_identities(text)
        self.assertEqual([(identity.sha1, identity.valid) for identity in identities], [(self.old, True)])

    def test_certificate_fields_and_sha1_come_from_the_der_bytes(self):
        certificates = self.m.parse_certificates("noise\n" + pem(self.old_der) + pem(self.new_der))
        old, new = certificates[self.old], certificates[self.new]
        self.assertEqual((old.subject_cn, old.subject_ou), (NAME, TEAM))
        self.assertEqual((old.issuer_cn, old.issuer_ou, old.sub_ca), (*G1, "G1"))
        self.assertEqual((new.issuer_ou, new.sub_ca), ("G2", "G2"))
        self.assertEqual(old.not_after, datetime(2027, 2, 1, 22, 12, 15, tzinfo=timezone.utc))
        self.assertIn("original Sub-CA", old.issuer_label())
        self.assertEqual(new.issuer_label(), "Developer ID Certification Authority (G2)")

    def test_generalized_time_and_foreign_issuers_are_read(self):
        der, digest = make(issuer=("Example Root", "Lab"), issued=datetime(2049, 6, 1, tzinfo=timezone.utc),
                           lasts=timedelta(days=400))
        certificate = self.m.parse_certificates(pem(der))[digest]
        self.assertEqual(certificate.not_after.year, 2050)
        self.assertIsNone(certificate.sub_ca)
        self.assertEqual(certificate.issuer_label(), "Example Root (Lab)")

    def test_unreadable_certificates_are_skipped_and_truncated_der_raises(self):
        self.assertEqual(self.m.parse_certificates("-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----\n"), {})
        with self.assertRaises(self.m.CertificateError):
            self.m.parse_certificate(self.old_der[:40])


class SelectionTests(DeveloperIDTestCase):
    def test_a_single_valid_identity_is_selected_by_name(self):
        selection = self.m.select_identity(*self.keychain([(self.old, NAME, None)], [self.old_der]), name=NAME)
        self.assertEqual(selection.identity.sha1, self.old)
        self.assertEqual(selection.reason, "the only valid identity with this name")

    def test_two_identities_with_one_name_fail_naming_both_candidates(self):
        identities, certificates = self.keychain([(self.old, NAME, None), (self.new, NAME, None)],
                                                 [self.old_der, self.new_der])
        with self.assertRaises(self.m.SigningIdentityError) as raised:
            self.m.select_identity(identities, certificates, name=NAME)
        message = str(raised.exception)
        for expected in (self.old, self.new, "original Sub-CA", "(G2)", "ambiguous", "--certificate-sha1",
                         "--certificate-policy newest-g2", "configure-machine --replace"):
            self.assertIn(expected, message)

    def test_a_sha1_picks_its_identity_while_both_are_installed(self):
        identities, certificates = self.keychain([(self.old, NAME, None), (self.new, NAME, None)],
                                                 [self.old_der, self.new_der])
        selection = self.m.select_identity(identities, certificates, name=NAME, certificate_sha1=self.new.lower())
        self.assertEqual(selection.identity.sha1, self.new)
        self.assertEqual(selection.certificate.sub_ca, "G2")

    def test_a_missing_or_foreign_sha1_is_refused(self):
        other_der, other = make(name="Developer ID Application: Other (OTHERTEAM1)", serial=9)
        identities, certificates = self.keychain([(self.old, NAME, None), (other, "Developer ID Application: Other (OTHERTEAM1)", None)],
                                                 [self.old_der, other_der])
        with self.assertRaises(self.m.SigningIdentityError) as missing:
            self.m.select_identity(identities, certificates, name=NAME, certificate_sha1="F" * 40)
        self.assertIn("unavailable", str(missing.exception))
        self.assertIn(self.old, str(missing.exception))
        with self.assertRaises(self.m.SigningIdentityError) as foreign:
            self.m.select_identity(identities, certificates, name=NAME, certificate_sha1=other)
        self.assertIn("does not match", str(foreign.exception))

    def test_newest_g2_policy_ignores_the_original_sub_ca_and_older_g2_identities(self):
        older_der, older = make(issuer=G2, issued=NOW - timedelta(days=300), serial=3)
        newest_g1_der, newest_g1 = make(issuer=G1, issued=NOW, lasts=timedelta(days=100), serial=4)
        rows = [(older, NAME, None), (newest_g1, NAME, None), (self.new, NAME, None)]
        identities, certificates = self.keychain(rows, [older_der, newest_g1_der, self.new_der])
        selection = self.m.select_identity(identities, certificates, name=NAME, policy="newest-g2")
        self.assertEqual(selection.identity.sha1, self.new)
        self.assertEqual(selection.reason, "newest G2 identity of the team")

    def test_newest_g2_policy_without_a_trusted_g2_identity_explains_the_intermediate(self):
        identities, certificates = self.keychain([(self.old, NAME, None), (self.new, NAME, "CSSMERR_TP_NOT_TRUSTED")],
                                                 [self.old_der, self.new_der])
        with self.assertRaises(self.m.SigningIdentityError) as raised:
            self.m.select_identity(identities, certificates, name=NAME, policy="newest-g2")
        self.assertIn("G2 Developer ID Sub-CA", str(raised.exception))
        self.assertIn("CSSMERR_TP_NOT_TRUSTED", str(raised.exception))

    def test_an_untrusted_identity_names_the_missing_intermediate(self):
        identities, certificates = self.keychain([(self.new, NAME, "CSSMERR_TP_NOT_TRUSTED")], [self.new_der])
        for kwargs in ({}, {"certificate_sha1": self.new}):
            with self.subTest(kwargs=kwargs), self.assertRaises(self.m.SigningIdentityError) as raised:
                self.m.select_identity(identities, certificates, name=NAME, **kwargs)
            self.assertIn("intermediate", str(raised.exception))

    def test_unchecked_expiry_and_conflicting_selectors_fail_closed(self):
        identities, _ = self.keychain([(self.new, NAME, None)], [])
        with self.assertRaises(self.m.SigningIdentityError) as raised:
            self.m.select_identity(identities, {}, name=NAME)
        self.assertIn("issuer and expiry cannot be checked", str(raised.exception))
        with self.assertRaises(self.m.SigningIdentityError):
            self.m.select_identity(identities, {}, name=NAME, certificate_sha1=self.new, policy="newest-g2")
        with self.assertRaises(self.m.SigningIdentityError):
            self.m.select_identity([], {}, name=NAME)


class AssessmentTests(DeveloperIDTestCase):
    def certificate(self, der):
        return self.m.parse_certificate(der)

    def test_the_original_sub_ca_warns_until_its_cutoff_and_fails_from_it(self):
        today = self.m.assess(self.certificate(self.old_der), NOW)
        self.assertEqual(today.status, "WARN")
        for expected in (self.old, "original Sub-CA", "2027-02-01 22:12:15 UTC", "create a G2 certificate", "113 days left"):
            self.assertIn(expected, today.detail)
        # A G1 leaf can never outlive its Sub-CA, but the cutoff holds even for one that claims to.
        long_der, _ = make(issuer=G1, issued=datetime(2026, 2, 4, tzinfo=timezone.utc), lasts=timedelta(days=700))
        cutoff = self.m.G1_SUB_CA_EXPIRY
        self.assertEqual(self.m.assess(self.certificate(long_der), cutoff - timedelta(seconds=1)).status, "WARN")
        after = self.m.assess(self.certificate(long_der), cutoff)
        self.assertEqual(after.status, "FAIL")
        self.assertIn("expired on 2027-02-01 22:12:15 UTC", after.detail)
        self.assertEqual(self.m.assess(self.certificate(self.old_der), cutoff).status, "FAIL")

    def test_a_g2_certificate_passes_then_warns_inside_sixty_days_then_fails_once_expired(self):
        certificate = self.certificate(self.new_der)
        passed = self.m.assess(certificate, NOW)
        self.assertEqual(passed.status, "PASS")
        self.assertIn("Developer ID Certification Authority (G2)", passed.detail)
        self.assertIn(f"to {certificate.not_after:%Y-%m-%d %H:%M:%S} UTC", passed.detail)
        self.assertEqual(self.m.assess(certificate, certificate.not_after - timedelta(days=61)).status, "PASS")
        warned = self.m.assess(certificate, certificate.not_after - timedelta(days=60))
        self.assertEqual(warned.status, "WARN")
        self.assertIn("within 60 days", warned.detail)
        failed = self.m.assess(certificate, certificate.not_after)
        self.assertEqual(failed.status, "FAIL")
        self.assertIn("expired", failed.detail)
        self.assertEqual(self.m.assess(certificate, certificate.not_before - timedelta(seconds=1)).status, "FAIL")

    def test_a_certificate_from_another_issuer_fails(self):
        der, _ = make(issuer=("Apple Development", "G3"))
        self.assertEqual(self.m.assess(self.certificate(der), NOW).status, "FAIL")


class KeychainQueryTests(DeveloperIDTestCase):
    def test_only_read_only_security_queries_run_and_the_keychain_is_passed_on(self):
        calls = []

        def run(argv):
            calls.append(argv)
            if argv[1] == "find-identity":
                return subprocess.CompletedProcess(argv, 0, find_identity_output([(self.new, NAME, None)]), "")
            return subprocess.CompletedProcess(argv, 0, pem(self.new_der), "")

        selection = self.m.select_from_keychain(run, name=NAME, keychain="/fake/release.keychain-db")
        self.assertEqual(selection.identity.sha1, self.new)
        self.assertEqual(calls, [["security", "find-identity", "-p", "codesigning", "/fake/release.keychain-db"],
                                 ["security", "find-certificate", "-a", "-c", NAME, "-p", "/fake/release.keychain-db"]])

    def test_a_failed_listing_fails_and_an_absent_name_skips_the_certificate_query(self):
        for status, output, expected in ((1, "", "find-identity failed"),
                                         (0, "     0 valid identities found\n", "unavailable")):
            calls = []

            def run(argv):
                calls.append(argv)
                return subprocess.CompletedProcess(argv, status, output, "")

            with self.subTest(status=status), self.assertRaises(self.m.SigningIdentityError) as raised:
                self.m.select_from_keychain(run, name=NAME)
            self.assertIn(expected, str(raised.exception))
            self.assertEqual([call[1] for call in calls], ["find-identity"])


class FakeSigningTools:
    """codesign and spctl doubles that answer like a G2 identity whose probe is signed but not notarized."""

    def __init__(self, test, *, timestamp=True, chain=None, spctl=None, sign_status=0):
        self.test, self.calls, self.signed_paths = test, [], []
        self.timestamp, self.sign_status = timestamp, sign_status
        self.chain = chain or [NAME, "Developer ID Certification Authority", "Apple Root CA"]
        self.spctl = spctl if spctl is not None else (3, f"rejected\nsource=Unnotarized Developer ID\norigin={NAME}\n")

    def __call__(self, argv):
        self.calls.append(argv)
        tool, path = Path(argv[0]).name, Path(argv[-1])
        if tool == "codesign" and "--sign" in argv:
            self.signed_paths.append(path)
            self.test.assertTrue((path / "Contents/MacOS/LungfishSigningProbe").is_file())
            return subprocess.CompletedProcess(argv, self.sign_status, "", "" if self.sign_status == 0 else "errSecInternalComponent")
        if tool == "codesign" and "--display" in argv:
            lines = [f"Authority={item}" for item in self.chain]
            lines += ["CodeDirectory v=20500 size=283 flags=0x10000(runtime) hashes=2+3 location=embedded",
                      f"TeamIdentifier={TEAM}"]
            lines.append("Timestamp=Oct 11, 2026 at 12:00:00" if self.timestamp else "Signed Time=Oct 11, 2026 at 12:00:00")
            return subprocess.CompletedProcess(argv, 0, "", "\n".join(lines) + "\n")
        if tool == "codesign":
            return subprocess.CompletedProcess(argv, 0, "", f"{path}: valid on disk\n")
        if tool == "spctl":
            return subprocess.CompletedProcess(argv, self.spctl[0], "", f"{path}: " + self.spctl[1])
        self.test.fail("unexpected tool: " + tool)


class VerifySigningTests(DeveloperIDTestCase):
    def setUp(self):
        super().setUp()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / "probes"
        self.workspace.mkdir()
        self.release = self.root / "build/Release/preview/candidate"
        self.release.mkdir(parents=True)
        (self.release / "Lungfish-2026.10.14-arm64.dmg").write_bytes(b"release artifact")
        self.selection = self.m.select_identity(*self.keychain([(self.new, NAME, None)], [self.new_der]), name=NAME)
        self.lines = []

    def verify(self, tools):
        tool_paths = {"codesign": "/fake/bin/codesign", "spctl": "/fake/bin/spctl", "security": "/fake/bin/security"}
        self.m.verify_signing(self.selection, team_id=TEAM, run=tools, keychain="/fake/release.keychain-db",
                              tools=tool_paths, emit=self.lines.append, temporary_root=self.workspace)

    def snapshot(self):
        return sorted((str(path.relative_to(self.root)), path.read_bytes() if path.is_file() else None)
                      for path in self.root.rglob("*") if not path.is_relative_to(self.workspace))

    def test_a_throwaway_bundle_is_signed_like_a_release_checked_and_deleted(self):
        before = self.snapshot()
        tools = FakeSigningTools(self)
        self.verify(tools)
        sign = next(argv for argv in tools.calls if "--sign" in argv)
        self.assertEqual(sign[:-1], ["/fake/bin/codesign", "--force", "--sign", self.new, "--timestamp",
                                     "--options", "runtime", "--keychain", "/fake/release.keychain-db"])
        self.assertTrue(tools.signed_paths[0].is_relative_to(self.workspace))
        self.assertEqual(list(self.workspace.iterdir()), [], "the temporary folder must be deleted")
        self.assertEqual(self.snapshot(), before, "no file outside the temporary folder may change")
        requirement = next(argv for argv in tools.calls if "-R" in argv)
        self.assertEqual(requirement[requirement.index("-R") + 1],
                         '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                         'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                         f'certificate leaf[subject.OU] = "{TEAM}"')
        self.assertIn(["/fake/bin/codesign", "--verify", "--strict", "--verbose=2", str(tools.signed_paths[0])], tools.calls)
        self.assertEqual([line.split(":")[0] for line in self.lines[:-1]],
                         ["PASS sign", "PASS verify", "PASS chain", "PASS team", "PASS timestamp",
                          "PASS hardened runtime", "PASS requirement", "PASS Gatekeeper"])
        self.assertIn("Unnotarized Developer ID", self.lines[-2])
        self.assertIn("no release artifact was touched", self.lines[-1])

    def test_each_missing_property_fails_at_its_step(self):
        cases = (
            ("sign", FakeSigningTools(self, sign_status=1), "errSecInternalComponent"),
            ("timestamp", FakeSigningTools(self, timestamp=False), "no secure timestamp"),
            ("chain", FakeSigningTools(self, chain=[NAME, "Apple Worldwide Developer Relations Certification Authority", "Apple Root CA"]), "Apple Worldwide"),
            ("Gatekeeper", FakeSigningTools(self, spctl=(3, "rejected\n")), "did not recognize"),
            ("Gatekeeper", FakeSigningTools(self, spctl=(3, "rejected\nsource=Unnotarized Developer ID\norigin=Developer ID Application: Other (OTHERTEAM1)\n")), "origin="),
        )
        for step, tools, expected in cases:
            with self.subTest(step=step, expected=expected):
                self.lines.clear()
                with self.assertRaises(self.m.SigningIdentityError) as raised:
                    self.verify(tools)
                self.assertIn(f"failed at {step}", str(raised.exception))
                self.assertIn(expected, self.lines[-1])
                self.assertEqual(list(self.workspace.iterdir()), [])

    def test_an_accepted_assessment_also_passes(self):
        self.verify(FakeSigningTools(self, spctl=(0, f"accepted\nsource=Notarized Developer ID\norigin={NAME}\n")))
        self.assertTrue(self.lines[-2].startswith("PASS Gatekeeper"))


class CommandLineTests(DeveloperIDTestCase):
    def setUp(self):
        super().setUp()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name).resolve()
        private = root / "private"
        private.mkdir(mode=0o700)
        self.profile = private / "profile.json"
        profiles = importlib.import_module("scripts.release.release_profiles")
        profiles.write_release_profile(self.profile, profiles.ReleaseProfile(
            "example/product", NAME, TEAM, "example-notary", schema_version=2))
        self.args = argparse.Namespace(profile=self.profile, repo=root, certificate_sha1=None)

    def fake(self, rows, ders, signing=None):
        calls = []

        def run(argv):
            calls.append(argv)
            if argv[1:2] == ["find-identity"]:
                return subprocess.CompletedProcess(argv, 0, find_identity_output(rows), "")
            if argv[1:2] == ["find-certificate"]:
                return subprocess.CompletedProcess(argv, 0, "".join(pem(der) for der in ders), "")
            if signing is None:
                self.fail("unexpected signing command: " + " ".join(argv))
            return signing(argv)
        return run, calls

    def test_show_lists_both_identities_then_names_the_ambiguity(self):
        run, calls = self.fake([(self.old, NAME, None), (self.new, NAME, None)], [self.old_der, self.new_der])
        with self.assertRaises(self.m.SigningIdentityError) as raised:
            self.m.show(self.args, run=run, now=NOW)
        self.assertIn(self.old, str(raised.exception))
        self.assertIn(self.new, str(raised.exception))
        self.assertEqual(calls[1][3:5], ["-c", "Developer ID Application"])

    def test_verify_with_an_override_signs_with_the_new_identity(self):
        tools = FakeSigningTools(self)
        run, calls = self.fake([(self.old, NAME, None), (self.new, NAME, None)], [self.old_der, self.new_der], tools)
        self.args.certificate_sha1 = self.new
        self.assertEqual(self.m.verify(self.args, run=run, now=NOW), 0)
        sign = next(argv for argv in calls if "--sign" in argv)
        self.assertEqual(sign[sign.index("--sign") + 1], self.new)
        self.assertNotIn("--keychain", sign)

    def test_verify_refuses_to_sign_with_a_certificate_that_fails_its_expiry_check(self):
        run, calls = self.fake([(self.old, NAME, None)], [self.old_der])
        self.assertEqual(self.m.verify(self.args, run=run, now=self.m.G1_SUB_CA_EXPIRY), 1)
        self.assertFalse(any("--sign" in argv for argv in calls))

    def test_show_without_a_profile_only_lists(self):
        run, _ = self.fake([(self.old, NAME, None)], [self.old_der])
        self.args.profile = self.profile.parent / "missing.json"
        self.assertEqual(self.m.show(self.args, run=run, now=NOW), 0)


if __name__ == "__main__":
    unittest.main()
