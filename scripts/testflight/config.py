"""Non-secret release validation; never emits credentials or raw profile contents."""
import base64
import datetime as dt
import json
import os
import plistlib
import re
import sys
from pathlib import Path


class ConfigurationError(ValueError):
    pass


def require(env, name):
    value = env.get(name, "")
    if not value:
        raise ConfigurationError(f"Set {name} in the GitHub testflight environment.")
    return value


def release_config(env):
    team = require(env, "APPLE_TEAM_ID")
    bundle = require(env, "APP_BUNDLE_ID")
    group = require(env, "APP_GROUP_ID")
    version = require(env, "APP_VERSION")
    build = require(env, "APP_BUILD_NUMBER")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ConfigurationError("APPLE_TEAM_ID must be the 10-character Apple team ID.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle) or bundle.startswith("com.example."):
        raise ConfigurationError("APP_BUNDLE_ID must be your registered explicit app identifier.")
    if len(bundle) > 240:
        raise ConfigurationError("APP_BUNDLE_ID is too long for its share-extension suffix.")
    if not re.fullmatch(r"group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", group) or group.startswith("group.com.example."):
        raise ConfigurationError("APP_GROUP_ID must be your registered App Group identifier.")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ConfigurationError("APP_VERSION must use major.minor.patch.")
    if not re.fullmatch(r"[1-9]\d{0,3}(?:\.\d{1,2}){0,2}", build):
        raise ConfigurationError("APP_BUILD_NUMBER must be a valid increasing bundle version, e.g. 12.1.")
    return {"team": team, "bundle": bundle, "shareBundle": bundle + ".Share",
            "group": group, "version": version, "build": build}


def decode_secret(env, name, path):
    raw = require(env, name)
    try:
        data = base64.b64decode("".join(raw.split()), validate=True)
    except (ValueError, base64.binascii.Error):
        raise ConfigurationError(f"{name} must contain base64-encoded file data.") from None
    if not data or len(data) > 10_000_000:
        raise ConfigurationError(f"{name} has an invalid file size.")
    Path(path).write_bytes(data)
    Path(path).chmod(0o600)


def validate_profile(profile, config, bundle, certificate_der, now=None):
    if not isinstance(profile, dict) or not isinstance(profile.get("Entitlements"), dict):
        raise ConfigurationError("A provisioning profile has invalid contents.")
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        raise ConfigurationError("A provisioning profile has no valid expiration.")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    if expiry <= now:
        raise ConfigurationError("A provisioning profile has expired.")
    if config["team"] not in profile.get("TeamIdentifier", []):
        raise ConfigurationError("A provisioning profile belongs to another Apple team.")
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("application-identifier") != config["team"] + "." + bundle:
        raise ConfigurationError("A provisioning profile does not match its explicit bundle ID.")
    if entitlements.get("get-task-allow", False) or profile.get("ProvisionsAllDevices") or "ProvisionedDevices" in profile:
        raise ConfigurationError("Use App Store Connect distribution profiles, not development/ad-hoc/enterprise profiles.")
    if config["group"] not in entitlements.get("com.apple.security.application-groups", []):
        raise ConfigurationError("Both provisioning profiles must include the registered App Group.")
    if certificate_der not in profile.get("DeveloperCertificates", []):
        raise ConfigurationError("A provisioning profile does not include the imported distribution certificate.")
    uuid = profile.get("UUID", "")
    if not re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", uuid):
        raise ConfigurationError("A provisioning profile has an invalid UUID.")
    return uuid


def validate_entitlements(entitlements, config, bundle):
    if not isinstance(entitlements, dict):
        raise ConfigurationError("Signed application entitlements are invalid.")
    if entitlements.get("application-identifier") != config["team"] + "." + bundle:
        raise ConfigurationError("Signed application identifier does not match the release.")
    if entitlements.get("com.apple.developer.team-identifier") != config["team"]:
        raise ConfigurationError("Signed application belongs to another team.")
    if config["group"] not in entitlements.get("com.apple.security.application-groups", []):
        raise ConfigurationError("Signed application is missing the selected App Group.")
    if entitlements.get("get-task-allow", False):
        raise ConfigurationError("The signed application permits development debugging.")


def validate_ipa(path, config):
    import zipfile
    with zipfile.ZipFile(path) as archive:
        infos = [name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info.plist", name)]
        if len(infos) != 1:
            raise ConfigurationError("Exported IPA must contain exactly one application.")
        app_path = infos[0].removesuffix("Info.plist")
        extension_infos = [name for name in archive.namelist()
                           if name.startswith(app_path + "PlugIns/") and name.endswith(".appex/Info.plist")]
        if len(extension_infos) != 1:
            raise ConfigurationError("Exported IPA must contain the Safari share extension.")
        for info_path, bundle in [(infos[0], config["bundle"]), (extension_infos[0], config["shareBundle"])]:
            info = plistlib.loads(archive.read(info_path))
            if info.get("CFBundleIdentifier") != bundle:
                raise ConfigurationError("Exported app/extension has an unexpected bundle identifier.")
            if info.get("CFBundleVersion") != config["build"] or info.get("CFBundleShortVersionString") != config["version"]:
                raise ConfigurationError("Exported app/extension versions do not match the selected release.")
            if info.get("ReadingCoachAppGroupIdentifier") != config["group"]:
                raise ConfigurationError("Exported app/extension uses an unexpected App Group.")
            embedded = info_path.removesuffix("Info.plist") + "embedded.mobileprovision"
            if embedded not in archive.namelist():
                raise ConfigurationError("Exported app/extension is missing an embedded distribution profile.")
        app_info = plistlib.loads(archive.read(infos[0]))
        icon = app_info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
        if icon.get("CFBundleIconName") != "AppIcon" or app_path + "Assets.car" not in archive.namelist():
            raise ConfigurationError("Exported application is missing its compiled AppIcon assets.")
        privacy_path = app_path + "PrivacyInfo.xcprivacy"
        if privacy_path not in archive.namelist():
            raise ConfigurationError("Exported application is missing its privacy manifest.")
        privacy = plistlib.loads(archive.read(privacy_path))
        if not any(item.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
                   and "CA92.1" in item.get("NSPrivacyAccessedAPITypeReasons", [])
                   for item in privacy.get("NSPrivacyAccessedAPITypes", [])):
            raise ConfigurationError("Exported privacy manifest is missing the app's UserDefaults reason.")


def main():
    config = release_config(os.environ)
    mode = sys.argv[1]
    work = Path(sys.argv[2])
    if mode == "decode":
        require(os.environ, "DISTRIBUTION_CERTIFICATE_PASSWORD")
        for name, filename in [("DISTRIBUTION_CERTIFICATE_P12_BASE64", "distribution.p12"),
                               ("APP_PROVISION_PROFILE_BASE64", "app.mobileprovision"),
                               ("SHARE_PROVISION_PROFILE_BASE64", "share.mobileprovision")]:
            decode_secret(os.environ, name, work / filename)
        (work / "config.json").write_text(json.dumps(config))
    elif mode == "profiles":
        cert = (work / "certificate.der").read_bytes()
        app = validate_profile(plistlib.loads((work / "app.plist").read_bytes()), config, config["bundle"], cert)
        share = validate_profile(plistlib.loads((work / "share.plist").read_bytes()), config, config["shareBundle"], cert)
        if app == share:
            raise ConfigurationError("App and share extension need separate provisioning profiles.")
        (work / "profile-ids.txt").write_text(app + "\n" + share + "\n")
        (work / "ExportOptions.plist").write_bytes(plistlib.dumps({
            "method": "app-store-connect", "destination": "export", "teamID": config["team"],
            "signingStyle": "manual", "signingCertificate": "Apple Distribution",
            "provisioningProfiles": {config["bundle"]: app, config["shareBundle"]: share},
            "manageAppVersionAndBuildNumber": False, "stripSwiftSymbols": True,
            "testFlightInternalTestingOnly": True,
        }))
    elif mode == "ipa":
        validate_ipa(work, config)
    elif mode == "signed":
        expected_ids = (work / "profile-ids.txt").read_text().splitlines()
        cert = (work / "certificate.der").read_bytes()
        for index, (name, bundle) in enumerate([("app", config["bundle"]), ("share", config["shareBundle"]) ]):
            entitlements = plistlib.loads((work / ("exported-" + name + ".entitlements.plist")).read_bytes())
            validate_entitlements(entitlements, config, bundle)
            profile = plistlib.loads((work / ("exported-" + name + ".profile.plist")).read_bytes())
            if validate_profile(profile, config, bundle, cert) != expected_ids[index]:
                raise ConfigurationError("Exported application contains an unexpected provisioning profile.")
    else:
        raise ConfigurationError("Unknown release validation command.")


if __name__ == "__main__":
    try:
        main()
    except ConfigurationError as error:
        # Messages contain fixed requirement names, never input or credential content.
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError):
        print("Release validation failed. Check signing files and package contents.", file=sys.stderr)
        sys.exit(1)
