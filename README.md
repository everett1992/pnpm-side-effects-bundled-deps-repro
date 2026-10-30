# pnpm: a package restored from the side-effects cache loses its bundled dependencies

A minimal reproduction for a pnpm bug.
A package that ships `bundledDependencies` in its tarball and has an allowed build script
is installed correctly the first time.
On the next install from the same store, pnpm restores it from the side-effects cache
without its `node_modules`, so `require()` of a bundled dependency fails.

## Run it

```sh
./repro.sh            # pnpm 11.28.9
./repro.sh 12.16.1    # any pnpm version
./repro.sh 11.28.9 'sideEffectsCache: false'
ALLOW_BUILD=false ./repro.sh 11.28.9
```

Needs Node.js, npm, curl and network access to registry.npmjs.org.
The script exits 1 when the bug reproduces.
Everything it creates goes in `.work/`.

## What the script does

1. Installs the requested pnpm version and [pnpr](https://github.com/pnpm/pnpm/tree/main/pnpr)
   (pnpm's registry server) into `.work/tools`.
2. Starts pnpr on `127.0.0.1:7677` with [`pnpr.yaml`](pnpr.yaml):
   `demo-bundler` is hosted locally, every other name is proxied from npmjs.
3. Publishes [`bundler/`](bundler/package.json) as `demo-bundler@1.0.0`.
   It bundles `is-number@7.0.0` and has `"postinstall": "echo built"`.
4. Installs [`app/`](app/package.json), which depends on `demo-bundler` and allows its build
   (`allowBuilds: { demo-bundler: true }`), on a fresh store, and runs `require('demo-bundler')`.
5. Deletes `app/node_modules`, installs again on the same (now warm) store, and runs the same `require`.

## Expected

Both installs give `demo-bundler` its bundled `node_modules/is-number`, and `require('demo-bundler')` works.

## Actual (pnpm 11.28.9)

```
install 1 (cold store): bundled is-number present: yes; require ok, isNumber(5) = true
install 2 (warm store): bundled is-number present: no; Cannot find module 'is-number'
RESULT: reproduced
```

After the first install, the store index entry for `demo-bundler@1.0.0` has a `sideEffects` entry
whose `deleted` list holds every bundled file (`node_modules/is-number/index.js`, `package.json`, ...).
The second install applies that diff and leaves the bundled files out.

## Version matrix

Linux x86_64, Node.js 26.12.0, pnpr 0.1.0-alpha.17, fresh store each run.

| pnpm | Setting | Install 1 (cold store) | Install 2 (warm store) |
|---|---|---|---|
| 10.34.9 | `allowBuilds: demo-bundler: true` | ok | **`Cannot find module 'is-number'`** |
| 11.28.5 | `allowBuilds: demo-bundler: true` | ok | **`Cannot find module 'is-number'`** |
| 11.28.9 (latest 11) | `allowBuilds: demo-bundler: true` | ok | **`Cannot find module 'is-number'`** |
| 11.28.10 (`next-11`) | `allowBuilds: demo-bundler: true` | ok | **`Cannot find module 'is-number'`** |
| 11.28.9 | the same, plus `sideEffectsCache: false` | ok | ok |
| 11.28.9 | `allowBuilds: demo-bundler: false` | ok | ok |
| 12.10.1 | `allowBuilds: demo-bundler: true` | ok | ok |
| 12.16.1 (latest) | `allowBuilds: demo-bundler: true` | ok | ok |
| 12.17.0 (`next-12`) | `allowBuilds: demo-bundler: true` | ok | ok |

pnpm 12 writes the same `deleted` list, but its restore keeps the package's `node_modules`.

## Workarounds

- `sideEffectsCache: false`, or
- deny the package's build (`allowBuilds: { <name>: false }`), if it does not need it.
