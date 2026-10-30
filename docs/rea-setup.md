# REA setup and verified capabilities

REA (Reverse Engineer Anything) helps an assistant inspect supplied application
artifacts and understand their behavior. It does not automatically reproduce an
application or make every analysis engine available.

## Official instructions inspected

- [REA README](https://github.com/morluto/rea#quick-start)
- [Installation and setup](https://github.com/morluto/rea/blob/main/docs/installation.md)
- [Codex configuration and troubleshooting](https://github.com/morluto/rea/blob/main/docs/client-configuration.md#codex-and-devin)

Documentation was inspected at upstream commit
`69bf61f7c72740b2eb9cfbd1474bcd61771d688b`. Installation uses the official npm
package `rea-agents@6.8.0`, not a source build or an unrelated package.

## What was installed

The original Node.js 24.19.0 does not meet REA 6.8.0's supported range:
`^22.23.4 || ^24.22.1 || >=26.12.1`. Node.js **24.22.1** was installed separately
under `/workspace/rea-runtime`; the system runtime was left unchanged. npm
**11.9.0** successfully installed the packages with normal integrity/TLS checks.

REA was installed with the documented global npm installation method, using a
workspace prefix, followed by `setup --client codex --yes --json`. Its matching
`reverse-engineer-anything` skill (version 49) and references were installed under
`~/.agents/skills`. MCP registration is in `$CODEX_HOME/config.toml`, which is
`/home/agent/.codex/config.toml` in this environment.

The scripts pin MCP's command to the compatible Node executable and its arguments
to REA's entry script plus `mcp`, using the documented manual launcher form. This
avoids REA 6.8.0 selecting a shebang alias that would otherwise depend on the
client's older default Node. Only REA's command and arguments are adjusted;
timeouts, unrelated settings, and original configuration backups are preserved.
No credentials are stored in this repository.

## Verification results

Verified in the existing environment on **30 October 2026**:

| Check | Observed result |
| --- | --- |
| Pinned npm installation | Passed |
| Re-run of `scripts/setup-rea.sh` | Passed |
| `doctor --client codex --skill --json` | Passed; registration and skill aligned |
| `mcp doctor --json` | Passed; 229/229 tools, 6/6 prompts, matching identity, successful `binary_session` |
| Local Codex client 0.163.0 | Discovered 229 tools, called `binary_session`, discovered the skill |
| Static JavaScript application smoke test | Recovered a known import and export with analysis evidence |
| Full `doctor --json` | Failed (exit 1): optional Hopper/Ghidra/IDA/JADX/Kuna engines missing |
| Direct REA tools in this active Cloud chat | Absent from the chat's available tool catalog |

The local Codex test uses the installed client's app-server API, starts an
ephemeral thread, discovers REA and calls the read-only tool directly. It does
not run a model turn, incur model inference, or prove that the hosted Cloud chat
loads the same local MCP configuration. The package and CLI work here; direct
Cloud chat MCP access must not be claimed. A new/reconnected client must be
checked separately. Installing files cannot add tools to an already-running chat.

The first MCP diagnostic inside the command sandbox failed with `Connection
closed`. The same official diagnostic passed outside that sandbox. The successful
checks here ran with the environment's reviewed execution permissions; restrictive
subprocess sandboxes may need a supported permission grant for those checks.

Native decompilation and JADX analysis have not been configured or verified.
These are missing optional providers, not evidence that Linux Cloud environments
can never support them. Chromium and procps-compatible `ps` were found, but REA
browser observation has not been tested. Remote targets remain subject to the
environment's network policy; no broader access or new credentials were added.

## Repeat the setup

From this repository:

```bash
bash scripts/setup-rea.sh
scripts/rea.sh doctor --client codex --skill --json
scripts/rea.sh mcp doctor --json
bash scripts/check-rea-static.sh
python3 scripts/check-rea-codex.py
```

The setup script requires an existing npm, Python 3.11+ (for TOML), procps `ps`,
and access to the official npm registry. The local-client probe additionally
requires the installed Codex CLI. `REA_RUNTIME_DIR` can override the installation
directory; keep it outside this checkout. Use the same setting for every script.

MCP runs on demand when a compatible client connects; no background REA daemon
must survive an environment snapshot. The wrapper works without changing the
user's shell PATH. If the snapshot lacks the installed files, rerun setup. Avoid
updating the pinned versions without checking runtime requirements, matching
skills, official diagnostics, and local Codex access again.

For a future task, you can simply ask the assistant:

> Use REA to analyze this application artifact, explain the evidence and
> limitations, and build an independent implementation of these features.

Supply the artifact or target and name the features you want. If direct MCP tools
are absent, the assistant should use `scripts/rea.sh` where the CLI supports the
task and clearly explain any remaining limitation.
