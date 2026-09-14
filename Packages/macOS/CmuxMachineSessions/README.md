# Machine sessions — private Tailscale pairing

The cmux app is both the client and the optional execution host. No SSH setup,
cloud account, T3 component, paid cmux service, or separately launched app is
required. The host must keep cmux running and remain awake on Tailscale.

## Try it

1. Run the same fork on both Macs, with both connected to your Tailscale network.
2. On the execution Mac, open **File → Agent Session on Computer…** (also in the
   workspace **+** menu), and choose **Share over Tailscale**.
3. Choose **Copy pairing code**. On the viewer Mac, paste it into **Add computer**
   and choose **Pair computer**. The invitation is single-use and expires after
   ten minutes; press **Share over Tailscale** again to generate another.
4. Select the paired Mac, an existing absolute project directory on that Mac,
   and Claude Code or Codex, then **Start session**. Agent installation, login,
   permission and project-trust prompts remain on the execution Mac. Nothing
   approves those prompts automatically.
5. Closing the viewer detaches it. Reopen the picker and choose **Open** to
   reconnect to the same live session, including from another paired Mac.
6. **End** plus confirmation terminates the exact agent session. **Stop sharing**
   disconnects viewers without ending agents. **Revoke all paired devices**
   invalidates their credentials and closes their connections immediately.

The native terminal bridge and tmux are bundled by `scripts/build-machine-helper.sh`;
only the build machine needs Homebrew tmux. Transitive native libraries and their
license notices travel with the bundle. The current local packaging path targets
the build machine's architecture.

The app restores an enabled host on launch using its saved port. If Tailscale is
not ready, open the picker and choose **Share over Tailscale** after connecting it.
There is no public-listener, DNS, SSH, or local-execution fallback on failure.

## Trust boundary

- The listener binds exclusively to the local numeric Tailscale IPv4 address
  (100.64.0.0/10). The client rejects DNS names, loopback and public endpoints.
  Only isolated test constructors permit loopback.
- Transport encryption and machine routing are supplied by Tailscale/WireGuard.
  Do not expose this protocol by port-forwarding or a public TCP proxy.
- A random 256-bit pairing secret authorizes one exchange. Each client receives
  a different 256-bit durable credential. Pairing grants cannot access sessions.
- The host stores only SHA-256 credential digests. Client credentials are in the
  build's private catalog, written atomically with mode 0600 from creation; the
  parent directory is created with mode 0700. Secrets never enter helper arguments.
  Do not log codes or include them in recordings.
- Sharing authorizes agent/terminal control as the host's logged-in user. Projects
  are not sandboxes. Pair only your own trusted devices.
- The versioned protocol allows pairing, provider discovery, managed-session
  list/create/end, and a bounded terminal stream. It does not forward arbitrary
  commands into cmux's control socket or change the SSH relay allowlist.
- Frames are bounded to 64 KiB; input chunks to 4 KiB; terminal dimensions to
  2–1000 cells; concurrent connections to 32. Unauthenticated connections expire.
  Slow terminal consumers are disconnected instead of silently losing output.

Sessions use stable `cmux-agent-<uuid>` identities. tmux retains the process and
metadata after viewer disconnects. Host reboot, agent exit, or explicit **End** ends
the live session. This version does not provide history import, reboot recovery,
file synchronization, iOS support, or T3 mobile compatibility.
Legacy saved SSH profiles remain readable, but new profiles use pairing only.

## Development and verification

`MachineSessionService` accepts an injected `CommandRunning` and binary directory.
Repositories take explicit file URLs. Tests use private temporary directories
and own only UUID-named disposable tmux sessions.

```sh
swift test --package-path Packages/macOS/CmuxMachineSessions
./scripts/reload.sh --tag fenix-machines --no-global-cli-links --launch
```

Tests exercise literal shell input, prerequisite errors, private-file modes,
corruption preservation, one-use pairing, revocation and restart persistence,
endpoint rejection, real TCP authentication, PTY input and resize, and paired TCP
terminal attach → detach → second attach → explicit end.
The legacy SSH test is opt-in via `CMUX_MACHINE_TEST_HOST`; it is not needed for
pairing. Local tests do not establish reachability of a second physical Mac.
Two-Mac dogfood requires installing this fork on that Mac.
