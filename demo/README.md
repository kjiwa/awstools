# Demo

`demo.gif` is recorded with [VHS](https://github.com/charmbracelet/vhs) against the repo's stub test harness — the `aws` CLI is the stub from [tests/stubs/](../tests/stubs/) fed by fixtures from [tests/fixtures/rds/](../tests/fixtures/rds/), and `docker` is replaced by [docker-stub](docker-stub), which plays a canned psql session. No AWS account, credentials, or Docker daemon are involved, which also makes the recording fully deterministic.

Everything shown up to and including "Connecting to ... as admin..." is rdsclient's real output; the psql banner and prompt afterward are simulated by the stub.

To regenerate:

```bash
brew install vhs   # or: go install github.com/charmbracelet/vhs@latest
vhs demo/demo.tape # from the repo root
```
