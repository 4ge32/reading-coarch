# Device acceptance checklist

These checks require a signed build on an actual iPhone; they are not recorded as
passed merely because the corresponding source exists.

1. Start in Demo with no backend. Open the labeled original sample, scroll,
   mark/unmark a sentence, undo, kill/relaunch, and verify marks and position.
   Confirm tapping neither opens a lesson nor sends a request. Measure marking
   latency on device (reference target p95 under 100 ms; no measurement yet).
2. Paste English containing repeated sentences, abbreviations, curly quotes,
   emoji, and headings. Preview before saving. Confirm distinct fixed sentence
   IDs and stable source text after reopening. Check large Dynamic Type, VoiceOver,
   Dark Mode, and scrolling without accidental marks.
3. Share a Safari article with a heading, list, quote, and code block. Confirm
   preview and save. Retry the same job without duplication. Simulate save failure
   and verify the inbox survives. URL-only shares must say the body is missing.
   Reimport the same URL; old marks must remain attached to the old snapshot.
4. Read stored source with slow/normal/fast presets, repeat, previous/next context,
   pause/resume/stop. Verify sentence highlighting and delegate range mapping.
   Missing English voices must show an error while leaving reading usable.
5. Configure a trusted HTTPS backend, high-entropy private app token, available
   OpenAI model IDs, and microphone permission. Confirm unauthenticated token
   requests fail. Confirm no app bundle, log, or persisted state contains provider
   keys or ephemeral credentials.
6. In Live, test text tutoring and real WebRTC microphone/audio with internal
   speaker and headphones. Check manual submit and automatic conversation.
   Distinguish connection time, finalized-turn time, and first-audio time.
7. Say “wait, still thinking,” then remain silent through multiple VAD events.
   No explanation, assessment, or navigation may occur until explicit release.
   Muted must mean no microphone transmission; voice-only unmute is not promised.
8. Test next/previous/defer/return, repeat source, and explicit finish. Navigation
   must not record understanding. Reaching the end must not finish automatically.
   Inject repeated tool IDs, invalid source IDs, and old state revisions.
9. Interrupt tutor audio and stop playback. Verify unfinished audio is cleared and
   conversation history truncation is consistent. Play source TTS while connected:
   it must stop tutor audio and pause microphone transmission, then restore only
   the eligible prior mode. Source audio must not be graded as a learner response.
10. Correct a bad transcript and re-evaluate. Old attempts become superseded and
    are excluded from current evidence. Check self-report, explanation exposure,
    supported answer, independent answer, oral repetition, and transfer evidence
    remain distinct.
11. Deny microphone, expire credentials, return quota/rate-limit failures, cut
    network, disconnect headphones, simulate interruption, lock/background, and
    foreground. Preserve articles and state, show errors, stop audio, and require
    explicit resume. Live must never silently become Demo.
12. Complete first-pass and rereading runs with tutoring and listening between.
    Confirm non-overlapping timings and separated WPM. Review unchecked/deferred
    and next-day items. Delete one article and verify other articles survive;
    delete all and verify inbox, local activity, and optional Keychain removal.
