# vidoas
vidoas - safely edit the doas.conf file (like visudo for doas)

vidoas opens a copy of `/etc/doas.conf` in your editor, checks it with `doas -C` and only installs it if the syntax is correct. A broken doas.conf can lock you out, so a file with errors is never saved.

Works with OpenDoas on Arch Linux, Debian, Ubuntu and other Linux distributions. Like visudo it must be run as root.

## Usage

```
vidoas [-chV] [-f file]

  -c, --check         check the file for syntax errors and bad permissions, do not edit
  -f, --file file     edit (or check) file instead of /etc/doas.conf
  -h, --help          display help message and exit
  -V, -v, --version   display version information and exit
```

If the edited file has a syntax error, doas prints the line and vidoas asks what to do:

```
doas: syntax error at line 2
vidoas: /etc/doas.conf not saved because of the error above
What now? (e)dit again, e(x)it without saving [e]:
```

The new file is written next to the old one and moved into place atomically, owned by root with mode 0400. A second vidoas in the same directory is refused while the first one is running (needs `flock` from util-linux, without it vidoas warns and edits without a lock). If `/etc/doas.conf` is a symlink, its target is edited.

## Editor

vidoas uses `$DOAS_EDITOR`, then `$EDITOR` (arguments are allowed, e.g. `EDITOR="code --wait"`). If neither is set, it takes the first of `editor`, `nano`, `vim` and `vi` that is installed.

doas does not pass your environment to root by default, so `$EDITOR` is often empty when you run `doas vidoas`. Either add `keepenv` (or `setenv { EDITOR }`) to your permit rule, or export `EDITOR` in root's shell profile.

Set `NO_COLOR` to disable colored messages.

## Installation

Arch Linux: install [vidoas from the AUR](https://aur.archlinux.org/packages/vidoas).

Other systems: copy `vidoas` to `/usr/local/bin/` (or `/usr/bin/`) and make it executable.

```
install -Dm755 vidoas /usr/local/bin/vidoas
```

## Tests

`tests/test.sh` runs the test suite (needs root, OpenDoas, expect and flock). It never touches `/etc/doas.conf`, all tests use `-f` with a temporary file.

```
sudo ./tests/test.sh
```

## Thanks

vidoas started as a fork of the version by Joshua Murphy (formerly at https://git.sr.ht/~insidepie/vidoas, no longer online). Thanks for the initial work.

Thanks to the Arch IRC, especially tirnanog, for tips and hints on making it fit Arch, and to [K0-RR](https://github.com/K0-RR) for the report and ideas in [#1](https://github.com/solisinvictum/vidoas/issues/1).
