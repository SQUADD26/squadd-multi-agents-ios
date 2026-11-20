# The real app against a live companion

Use this when a proof needs the real app talking to a real Squadd companion: pairing, presence, chat, links. It works from the Linux sandbox. #8, #11 and #33 each rebuilt it by hand; #33 marked the proof impossible and the PR judge said NO.

```bash
scripts/pr-ios-run live <issue> <TestClass>[/<testMethod>]
```

It runs that test of this checkout's committed HEAD on the Mac runner against a disposable openmausbot server and companion in the sandbox, behind a serveo tunnel, and cleans up after itself; its docstring lists each step. Scripted replies pass through the environment: `FAKE_CLAUDE_REPLIES='["first","second"]'`, streamed in pieces with `FAKE_CLAUDE_STREAM_CADENCE=8:150`; with none of `FAKE_CLAUDE_REPLIES`, `FAKE_CLAUDE_STREAM_CADENCE` or `FAKE_CLAUDE_MODE` set, the launcher streams a long reply of its own, or a turn that stays running until you release it, `FAKE_CLAUDE_MODE=hang FAKE_CLAUDE_RELEASE=<file>`. The test runs only when its environment names the lookup and the token, and re-reads the gist on each try (16 tries every 15 s), as `liveAddress` in `SquaddChatLivePhotoTests`. While the run goes, the companion's side of the record (for example `lastActiveAt` in `brief.json`) is in the server data folder the launcher prints. A live run holds a Mac runner for minutes: run it once per PR, when the work is done and PR iOS is green.

**Approval cards**: `OMB_VERIFY_APPROVALS=mcp scripts/pr-ios-run live …` (openmausbot `control-omb.ts launch`) puts the starter bot on the fake ACP engine at Ask: every message raises a real card, and «Always allow» carries its `allowKey`, as `testPhotographALiveApproval` checks. `OMB_VERIFY_APPROVALS=shell` gives the shell card, which never carries one.

**A real push** in the simulator (banner, tap, the thread it opens): `scripts/pr-ios-run live <issue> --push` (`scripts/pr-ios-push.yml`, `docs/agents/push.md`).
