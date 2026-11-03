import copy
import datetime as dt
import importlib.util
import os
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_config", ROOT / "scripts/testflight/config.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
DIAGNOSTIC_SPEC = importlib.util.spec_from_file_location("release_diagnostics", ROOT / "scripts/testflight/diagnostics.py")
diagnostics = importlib.util.module_from_spec(DIAGNOSTIC_SPEC)
DIAGNOSTIC_SPEC.loader.exec_module(diagnostics)
ENV = {"APPLE_TEAM_ID": "ABCD123456", "APP_BUNDLE_ID": "dev.reader.ReadingCoach",
       "APP_GROUP_ID": "group.dev.reader.ReadingCoach", "APP_VERSION": "0.1.0", "APP_BUILD_NUMBER": "42.2"}


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.config = release.release_config(ENV)
        self.certificate = b"unit-test-certificate"
        self.now = dt.datetime(2026, 10, 31, tzinfo=dt.timezone.utc)
        self.profile = {
            "UUID": "12345678-1234-1234-1234-123456789abc", "TeamIdentifier": [self.config["team"]],
            "ExpirationDate": self.now + dt.timedelta(days=30), "DeveloperCertificates": [self.certificate],
            "Entitlements": {"application-identifier": self.config["team"] + "." + self.config["bundle"],
                             "com.apple.security.application-groups": [self.config["group"]], "get-task-allow": False},
        }

    def test_config_uses_separate_explicit_share_identifier(self):
        self.assertEqual(self.config["shareBundle"], "dev.reader.ReadingCoach.Share")
        for name in ENV:
            with self.subTest(missing=name), self.assertRaises(release.ConfigurationError):
                release.release_config({k: v for k, v in ENV.items() if k != name})

    def test_placeholders_and_shell_like_ids_are_rejected(self):
        for name, value in [("APPLE_TEAM_ID", "invalid"), ("APP_BUNDLE_ID", "com.example.ReadingCoach"),
                            ("APP_BUNDLE_ID", "dev.reader;echo injected"), ("APP_GROUP_ID", "group.com.example.Reader"),
                            ("APP_VERSION", "one"), ("APP_BUILD_NUMBER", "0"), ("APP_BUILD_NUMBER", "42.100")]:
            with self.subTest(name=name, value=value), self.assertRaises(release.ConfigurationError):
                release.release_config({**ENV, name: value})

    def test_valid_app_store_profile_matches_identity_group_and_certificate(self):
        self.assertEqual(release.validate_profile(self.profile, self.config, self.config["bundle"], self.certificate, self.now), self.profile["UUID"])

    def test_wrong_team_source_bundle_certificate_group_and_expiry_are_rejected(self):
        changes = [lambda p: p.update(TeamIdentifier=["OTHER12345"]),
                   lambda p: p.update(ExpirationDate=self.now - dt.timedelta(seconds=1)),
                   lambda p: p.update(DeveloperCertificates=[b"different"]),
                   lambda p: p["Entitlements"].update({"application-identifier": "ABCD123456.dev.reader.Wrong"}),
                   lambda p: p["Entitlements"].update({"com.apple.security.application-groups": []})]
        for change in changes:
            with self.subTest(change=change):
                profile = copy.deepcopy(self.profile)
                change(profile)
                with self.assertRaises(release.ConfigurationError):
                    release.validate_profile(profile, self.config, self.config["bundle"], self.certificate, self.now)

    def test_development_adhoc_and_enterprise_profiles_are_not_testflight_signing(self):
        for values in [{"ProvisionedDevices": ["test-device"]}, {"ProvisionsAllDevices": True}]:
            with self.subTest(values=values), self.assertRaises(release.ConfigurationError):
                release.validate_profile({**self.profile, **values}, self.config, self.config["bundle"], self.certificate, self.now)
        profile = copy.deepcopy(self.profile)
        profile["Entitlements"]["get-task-allow"] = True
        with self.assertRaises(release.ConfigurationError):
            release.validate_profile(profile, self.config, self.config["bundle"], self.certificate, self.now)

    def test_bad_profile_uuid_cannot_become_a_filesystem_path(self):
        with self.assertRaises(release.ConfigurationError):
            release.validate_profile({**self.profile, "UUID": "../../file"}, self.config, self.config["bundle"], self.certificate, self.now)

    def test_signed_entitlements_must_match_profile_release_and_disable_debugging(self):
        entitlements = {**self.profile["Entitlements"], "com.apple.developer.team-identifier": self.config["team"]}
        release.validate_entitlements(entitlements, self.config, self.config["bundle"])
        for changed in [{"com.apple.developer.team-identifier": "wrong"}, {"get-task-allow": True},
                        {"application-identifier": "ABCD123456.dev.reader.Wrong"}]:
            with self.subTest(changed=changed), self.assertRaises(release.ConfigurationError):
                release.validate_entitlements({**entitlements, **changed}, self.config, self.config["bundle"])

    def test_base64_files_are_private_and_invalid_data_is_not_echoed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "file"
            release.decode_secret({"CERT": "dGVzdA==\n"}, "CERT", path)
            self.assertEqual(path.read_bytes(), b"test")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(release.ConfigurationError) as error:
                release.decode_secret({"CERT": "private-invalid-value"}, "CERT", path)
            self.assertNotIn("private-invalid-value", str(error.exception))

    def make_ipa(self, path, mutate=None):
        entries = {}
        for base, bundle in [("Payload/ReadingCoach.app/", self.config["bundle"]),
                             ("Payload/ReadingCoach.app/PlugIns/ReadingCoachShare.appex/", self.config["shareBundle"])]:
            info = {"CFBundleIdentifier": bundle, "CFBundleVersion": self.config["build"],
                    "CFBundleShortVersionString": self.config["version"], "ReadingCoachAppGroupIdentifier": self.config["group"],
                    "UIDeviceFamily": [1]}
            if bundle == self.config["bundle"]:
                info["CFBundleIcons"] = {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}}
            entries[base + "Info.plist"] = plistlib.dumps(info)
            entries[base + "embedded.mobileprovision"] = b"profile-fixture"
        entries["Payload/ReadingCoach.app/Assets.car"] = b"compiled-assets-fixture"
        entries["Payload/ReadingCoach.app/PrivacyInfo.xcprivacy"] = plistlib.dumps({"NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}]})
        if mutate:
            mutate(entries)
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)

    def test_exported_ipa_requires_app_extension_icon_privacy_profile_and_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.ipa"
            self.make_ipa(path)
            release.validate_ipa(path, self.config)
            for missing in ["Payload/ReadingCoach.app/Assets.car", "Payload/ReadingCoach.app/PrivacyInfo.xcprivacy",
                            "Payload/ReadingCoach.app/PlugIns/ReadingCoachShare.appex/embedded.mobileprovision"]:
                self.make_ipa(path, lambda entries: entries.pop(missing))
                with self.subTest(missing=missing), self.assertRaises(release.ConfigurationError):
                    release.validate_ipa(path, self.config)
            def wrong_version(entries):
                key = "Payload/ReadingCoach.app/PlugIns/ReadingCoachShare.appex/Info.plist"
                info = plistlib.loads(entries[key]); info["CFBundleVersion"] = "1"
                entries[key] = plistlib.dumps(info)
            self.make_ipa(path, wrong_version)
            with self.assertRaises(release.ConfigurationError):
                release.validate_ipa(path, self.config)

    def test_exported_ipa_rejects_unintended_ipad_target_for_app_and_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.ipa"
            for info_path in ["Payload/ReadingCoach.app/Info.plist",
                              "Payload/ReadingCoach.app/PlugIns/ReadingCoachShare.appex/Info.plist"]:
                def add_ipad(entries):
                    info = plistlib.loads(entries[info_path])
                    info["UIDeviceFamily"] = [1, 2]
                    entries[info_path] = plistlib.dumps(info)
                self.make_ipa(path, add_ipad)
                with self.subTest(info_path=info_path), self.assertRaisesRegex(release.ConfigurationError, "iPhone only"):
                    release.validate_ipa(path, self.config)


class SigningPreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "signing"
        self.env = {**os.environ, "DISTRIBUTION_CERTIFICATE_PASSWORD": "unit-test-password-not-a-credential"}

    def run_script(self, name, check=True, env=None):
        return subprocess.run(["bash", str(ROOT / "scripts/testflight" / name), str(self.path)],
                              env=env or self.env, capture_output=True, text=True, check=check)

    def test_csr_contains_no_unencrypted_private_key_and_refuses_overwrite(self):
        result = self.run_script("create-csr.sh")
        self.assertIn("encrypted", result.stdout)
        self.assertIn("ENCRYPTED PRIVATE KEY", (self.path / "distribution-key.pem").read_text())
        self.assertIn("CERTIFICATE REQUEST", (self.path / "distribution.csr").read_text())
        before = (self.path / "distribution-key.pem").read_bytes()
        self.assertNotEqual(self.run_script("create-csr.sh", check=False).returncode, 0)
        self.assertEqual(before, (self.path / "distribution-key.pem").read_bytes())

    def make_certificate(self, csr):
        # A local self-signed test certificate exercises packaging only; Apple signing remains unrun.
        subprocess.run(["openssl", "x509", "-req", "-in", str(csr), "-signkey", str(self.path / "distribution-key.pem"),
                        "-passin", "env:DISTRIBUTION_CERTIFICATE_PASSWORD", "-days", "1", "-outform", "DER",
                        "-out", str(self.path / "distribution.cer")], env=self.env, check=True, capture_output=True)

    def test_p12_round_trip_matches_csr_key_and_refuses_overwrite(self):
        self.run_script("create-csr.sh")
        self.make_certificate(self.path / "distribution.csr")
        self.run_script("create-p12.sh")
        subprocess.run(["openssl", "pkcs12", "-in", str(self.path / "distribution.p12"), "-passin",
                        "env:DISTRIBUTION_CERTIFICATE_PASSWORD", "-noout"], env=self.env, check=True, capture_output=True)
        self.assertEqual((self.path / "distribution.p12").stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(self.run_script("create-p12.sh", check=False).returncode, 0)

    def test_missing_password_does_not_generate_private_key(self):
        env = {key: value for key, value in self.env.items() if key != "DISTRIBUTION_CERTIFICATE_PASSWORD"}
        self.assertNotEqual(self.run_script("create-csr.sh", check=False, env=env).returncode, 0)
        self.assertFalse(self.path.exists())

    def test_wrong_certificate_does_not_package_a_mismatched_key(self):
        self.run_script("create-csr.sh")
        subprocess.run(["openssl", "req", "-newkey", "rsa:2048", "-x509", "-nodes", "-days", "1",
                        "-subj", "/CN=Different test identity", "-keyout", str(Path(self.directory.name) / "other-key.pem"),
                        "-outform", "DER", "-out", str(self.path / "distribution.cer")], check=True, capture_output=True)
        result = self.run_script("create-p12.sh", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        self.assertFalse((self.path / "distribution.p12").exists())


class ReleaseDiagnosticTests(unittest.TestCase):
    def test_error_summary_redacts_credentials_profiles_keys_and_keeps_apple_code(self):
        text = """error: password=pw-sentinel and account key-id-sentinel
error: Authorization: Bearer token-sentinel
error: {"token":"json-token-sentinel"}
error: provisioning profile "private-profile-name" has expired
error: keychain /tmp/private.keychain-db failed
-----BEGIN PRIVATE KEY-----
error: private-key-sentinel
-----END PRIVATE KEY-----
error: ITMS-90161 invalid provisioning profile; private-issuer-sentinel
"""
        env = {"DISTRIBUTION_CERTIFICATE_PASSWORD": "pw-sentinel", "ASC_KEY_ID": "key-id-sentinel",
               "ASC_ISSUER_ID": "private-issuer-sentinel"}
        summary = "\n".join(diagnostics.summarize(text, env))
        for secret in ["pw-sentinel", "key-id-sentinel", "token-sentinel", "private-profile-name",
                       "private-key-sentinel", "private-issuer-sentinel", "json-token-sentinel", "/tmp/private.keychain-db"]:
            self.assertNotIn(secret, summary)
        self.assertIn("ITMS-90161", summary)

    def test_success_log_lines_are_omitted_and_summary_is_bounded(self):
        text = "successful ordinary output\n" + "\n".join(f"error: code {i} " + "x " * 800 for i in range(30))
        summary = diagnostics.summarize(text, {})
        self.assertEqual(len(summary), 12)
        self.assertTrue(all(len(line) <= 600 for line in summary))
        self.assertNotIn("successful ordinary output", "\n".join(summary))


if __name__ == "__main__":
    unittest.main()
