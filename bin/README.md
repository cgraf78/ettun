# Executable

`ettun` is intentionally shipped as one self-contained Bash program. Its local
launcher, ET transport lifecycle, generated remote supervisor, and cleanup
protocol change together; splitting those pieces into separately installed
libraries would add version and lookup boundaries without creating a reusable
public API.

The stable command surface is:

```text
ettun VIA LOCAL_PORT TARGET TARGET_PORT
```

The supported configuration variables and custom-adapter contract are
documented in the repository [`README`](../README.md). Internal worker modes,
wire markers, generated shell functions, and temporary files are implementation
details. Consumers should expose `bin/ettun` directly instead of adding wrapper
scripts, so argument handling, signal ownership, and exit statuses remain the
same in every installation.

Comments in `bin/ettun` emphasize ordering and ownership rather than restating
syntax. Much of the code coordinates Bash job control, terminal foreground
handoff, and remote process cleanup; moving a publication or trap across a
process launch can change correctness even when the resulting shell still looks
equivalent.
