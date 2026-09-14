# Machine sessions

Host-owned Claude Code and Codex sessions over existing SSH connections (use Tailscale hostnames or aliases pointing to the tailnet). No cloud account, paid cmux service, provider credential upload, or public listener is required.

`MachineSessionService` uses an injected `CommandRunning`; tests can instantiate it with a scripted runner and an explicit local working directory. `MachineProfileRepository` takes a file URL, so tests use a temporary catalog without reading the user's settings.

The execution host needs tmux 3.2+, a project directory, and the selected agent on its login-shell PATH. SSH authentication and host-key verification use OpenSSH defaults and the user's existing configuration. Set up key access once with `ssh user@host` before connecting from the app. Unknown host keys and failed authentication are surfaced; they never fall back to local execution.

Session metadata lives in tmux's per-session environment (`CMUX_MACHINE_TITLE`, `CMUX_MACHINE_PROJECT`, `CMUX_MACHINE_AGENT`). A fresh client discovers sessions directly from the host. The `cmux-agent-<uuid>` name remains opaque and stable. Detaching a viewer does not terminate the agent; End explicitly kills its exact managed tmux session. Rebooting the host or exiting the agent ends its live session; this version does not claim reboot recovery or conversation-history synchronization.

Run focused tests with `swift test --package-path Packages/macOS/CmuxMachineSessions`.

## Trying the macOS UI

1. Build and launch an isolated copy: `./scripts/reload.sh --tag fenix-machines --no-global-cli-links --launch`.
2. Open **File → Agent Session on Computer…** (also available in the workspace **+** menu).
3. Select this computer, or save a name and `user@machine.tailnet.ts.net` / configured SSH alias. The machine catalog is local to this build; add the same host on each viewer Mac.
4. Select Claude Code or Codex, enter an existing absolute project path **on that host**, and choose **Start session**. Agent authentication and any trust/onboarding prompts appear in its terminal; no prompt is automatically approved.
5. Close the resulting workspace. Reopen the picker and choose **Open** on the same session. From another Mac running this fork, add the same SSH host and account to discover it.
6. Use **End**, then confirm, only when you want to stop the agent and its processes.

For Mac hosts, enable macOS **Remote Login** for the intended account. Install tmux and the desired agents on that Mac, and verify `ssh user@host` works with key authentication before adding it. Tailscale provides the network route; it does not automatically enable macOS SSH or synchronize repositories. No automatic host discovery, file synchronization, agent history import, mobile UI, or restart recovery is included in this first version.

Remote terminals use cmux's existing native tmux mirror. Managed `cmux-agent-<uuid>` sessions opt out of workspace-close and app-quit kill paths, including after restoration; ordinary remote tmux sessions retain their existing behavior. Renaming a managed workspace changes its local presentation, not the stable remote ID. Local terminals use a regular tmux attachment.

Verification includes shell-injection inputs, failed SSH without local fallback, prerequisite errors, catalog persistence/corruption, managed-only discovery, and a live tmux create → attach → detach → discover from a second service → idempotent retry → explicit termination test. A real two-Mac test additionally requires the remote machine's SSH access; local tests do not establish Tailscale reachability.
