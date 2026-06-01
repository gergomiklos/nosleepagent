# NoSleepAgent

Keeps your Mac awake while your agents are working — close the lid and the job keeps running. Once they are idle, normal sleep comes back.

## How it works

Claude Code hooks stamp a "last activity" time on every prompt and tool call. A
root daemon checks it every 30s:

- active in the last 10 min → `pmset disablesleep 1` (stay awake, lid open or closed)
- idle → `pmset disablesleep 0` (sleep normally)

No UI, no state machine. Just a timestamp.

## Install

```bash
git clone https://github.com/gergomiklos/nosleepagent.git
cd nosleepagent
./install.sh
```

Wires up the hooks (backs up your settings), installs the daemon, adds a
`/nosleep` command. Needs `sudo` (flipping `disablesleep` is root-only). Works on
any Mac. Restart open Claude Code sessions afterward.

## Use

Nothing — it just runs. To turn it off: `./ctl.sh off` (`on` / `status`), or
`/nosleep off` inside Claude Code.

## Uninstall

```bash
./uninstall.sh
```

Removes the daemon and re-enables normal sleep.

## License

MIT — see [LICENSE](LICENSE).
