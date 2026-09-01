# Contributing to ImageCraft

This project is under active development. Changes should preserve the documented
contract boundaries, add or update executable tests, and state any unverified
assumptions or current contract effects.

Before opening a pull request, run the repository's documented verification entrypoint:

```sh
scripts/verify.sh
```

Repository governance treats `develop` as a long-lived integration branch. Changes enter `main` through the repository's squash-only flow; `main` has a strict required `core` check that also applies to administrators, force-push and branch deletion are disabled, and merged source branches are not deleted automatically so `develop` is preserved.

Do not commit credentials, local absolute paths, device identifiers, build products,
or private test data. Contributions are submitted under the repository's MIT License.
