# Try ReadingCoach on iPhone without a Mac

This route uses GitHub's macOS runner to build and sign the native app, and Apple's
TestFlight app to install it. Start with Demo: it does not need a backend or an
OpenAI key. Live text/voice setup is separate and described in the root README.

The repository includes the workflow and preparation scripts. An actual signed
build and TestFlight upload have **not** been observed. The developer account is
enrolled; the identifiers, signing files, GitHub secrets, and App Store Connect
records still need to be checked before distribution. Unsigned Simulator artifacts
and downloaded App Store IPAs cannot be installed by tapping them on your iPhone.

## 1. Enroll and create the app records

Enroll in the [Apple Developer Program](https://developer.apple.com/programs/enroll/).
Once membership is active, use the Developer website and App Store Connect in a
browser. Accept any pending developer agreements.

Verify that these identifiers are registered for the selected Apple team:

| Item | Value |
| --- | --- |
| Apple Team ID | `MFD926L2J2` |
| Main app bundle ID | `com.4ge32.readingcoach` |
| Share extension bundle ID | `com.4ge32.readingcoach.Share` |
| App Group | `group.com.4ge32.readingcoach.shared` |

Enable the App Groups capability on **both** explicit bundle IDs and attach the
same group to both. Find your 10-character Team ID in your Developer membership
details. Create an iOS app in App Store Connect using the main bundle ID; the
extension is part of that app, not a separate App Store record.

## 2. Prepare a signing certificate using a browser terminal

A Mac is not required for this step. A GitHub Codespace opened on this repository,
or another Linux terminal with Git, OpenSSL, and GitHub CLI, can run these scripts.
Use the `codex/reading-coach-v0-1` branch until the PR has been merged.

Choose a password locally; do not send it or any key/certificate file in chat:

```sh
read -r -s -p 'Choose a signing password: ' DISTRIBUTION_CERTIFICATE_PASSWORD
echo
export DISTRIBUTION_CERTIFICATE_PASSWORD
bash scripts/testflight/create-csr.sh
```

This creates an encrypted private key and a public CSR in ignored `.signing/`.
Download **only** `.signing/distribution.csr` from your browser terminal and upload
it to Apple's Certificates page when creating an **Apple Distribution** certificate.
Download the resulting `.cer`, upload it to the terminal as
`.signing/distribution.cer`, then run:

```sh
bash scripts/testflight/create-p12.sh
```

The script checks certificate expiry and that it matches the private key, then
creates encrypted `.signing/distribution.p12`. Keep a secure backup of your
encrypted key and password. The scripts refuse to overwrite an existing identity.

On the Developer website, create **two App Store Connect distribution provisioning
profiles** using that certificate: one for the main app and one for the share
extension. Both must include the registered App Group. Download them to
`.signing/app.mobileprovision` and `.signing/share.mobileprovision`. Development,
ad hoc, and enterprise profiles are not accepted by this workflow.

## 3. Create the GitHub environment

In this repository's **Settings → Environments**, create an environment named
`testflight`. An optional required reviewer can make signed builds require a
deliberate approval; configure it so your intended operator can approve runs.
Restrict that environment's deployment branches to your trusted default branch.
Run signing only from reviewed workflow/script code on that branch.

The project and workflow default to the identifiers above. These optional
environment **variables**, if set, override the workflow defaults:

| Name | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `MFD926L2J2` |
| `APP_BUNDLE_ID` | `com.4ge32.readingcoach` |
| `APP_GROUP_ID` | `group.com.4ge32.readingcoach.shared` |

Add these environment **secrets**, never repository files or chat messages:

| Name | Contents |
| --- | --- |
| `DISTRIBUTION_CERTIFICATE_P12_BASE64` | Base64 of `distribution.p12` |
| `DISTRIBUTION_CERTIFICATE_PASSWORD` | Password chosen above |
| `APP_PROVISION_PROFILE_BASE64` | Base64 of main app profile |
| `SHARE_PROVISION_PROFILE_BASE64` | Base64 of extension profile |

GitHub CLI can save them without printing their contents:

```sh
base64 < .signing/distribution.p12 | gh secret set DISTRIBUTION_CERTIFICATE_P12_BASE64 --env testflight
printf '%s' "$DISTRIBUTION_CERTIFICATE_PASSWORD" | gh secret set DISTRIBUTION_CERTIFICATE_PASSWORD --env testflight
base64 < .signing/app.mobileprovision | gh secret set APP_PROVISION_PROFILE_BASE64 --env testflight
base64 < .signing/share.mobileprovision | gh secret set SHARE_PROVISION_PROFILE_BASE64 --env testflight
unset DISTRIBUTION_CERTIFICATE_PASSWORD
```

Use your repository's secure environment UI or an authorized GitHub CLI session.

## 4. Enable App Store Connect upload

In App Store Connect's **Users and Access → Integrations → App Store Connect API**,
create a team API key with permission to upload builds, such as Developer.
The Account Holder may need to enable API access first. Download its `.p8` once
and save it securely. Team keys apply to every app in the account within the
selected role's permissions. This is an Apple upload key, not your OpenAI key.

Add these secrets to the same GitHub `testflight` environment:

| Name | Contents |
| --- | --- |
| `ASC_KEY_ID` | API key ID |
| `ASC_ISSUER_ID` | Team API issuer UUID |
| `ASC_PRIVATE_KEY_P8` | Full unencoded `.p8` file contents |

For the private key, use a file input instead of printing it:

```sh
gh secret set ASC_PRIVATE_KEY_P8 --env testflight < /path/to/AuthKey_YOUR_KEY_ID.p8
```

Signing certificates/profiles and App Store Connect keys are independent. An
OpenAI API key is never needed by the build/upload workflow or placed in the app.

## 5. Run the cloud build

The **Check** workflow runs on PR updates and performs portable checks plus a
macOS Simulator build/test. Resolve build failures before distribution. The
TestFlight workflow also requires its own successful Simulator job before signing.

GitHub displays the **Run workflow** button for `workflow_dispatch` after the
workflow file is present on the repository's default branch. Once reviewed changes
and their checks are merged into the default branch, open
**Actions → iPhone build and TestFlight → Run workflow**.

- With both checkboxes off, it runs unsigned Simulator validation only. No Apple
  secrets or environment approval are used.
- To inspect a signed build first, select `build_signed_ipa` and leave upload off.
  The IPA artifact expires after three days. It is for inspection; it is not a
  direct download-and-install route.
- To distribute to yourself, select `upload_to_testflight`. This also builds a
  signed IPA after validation and uses the configured `testflight` environment.
  It uploads for **internal TestFlight testing only**, not an App Store release.

Use a valid app version, initially `0.1.0`, and an increasing build number. The
default is `run-number.run-attempt`; retries get a new build suffix. If a higher
build was previously uploaded from another system, enter a higher build manually.
Both app and extension receive the same version/build values. The workflow checks
the team, exact bundle IDs, App Group, certificate membership and profile expiry.
It imports signing files into a temporary keychain and removes local credentials
and release outputs after the run. The upload API key is exposed only to the
explicit upload step.

The selected runner is `macos-26` with Xcode `26.6`. This installation was verified
in the official GitHub runner inventory. Apple's current submission requirements
must still be checked when you upload; the Apple requirements page could not be
read from this task's network. A workflow source file is not proof of a successful
archive or upload.

## 6. Install through TestFlight

After App Store Connect processes the uploaded build, handle any export-compliance
or account prompts it presents. The current app uses standard transport encryption
and declares no non-exempt encryption; review this if its crypto features change.
App Store Connect privacy disclosures are separate from the included UserDefaults
required-reason API manifest. Live sends selected text/answers/audio to providers;
do not describe Live as entirely on-device.

In the app's **TestFlight** tab, create an internal testing group, add your own
App Store Connect user, and assign the processed build. Install Apple's TestFlight
app on your iPhone, accept the invitation with that Apple account, and install
ReadingCoach. External testers and public invitations are outside this setup.

Leave ReadingCoach in **Demo** for the first run. Try the sample, sentence marks,
paste import, source TTS and Safari share import. Native behavior remains a device
validation gate; report an error or a failed cloud build log so it can be fixed.
Then follow the README's private HTTPS backend instructions if you want Live.
