# CLAUDE.md: handover for AI agents

This repo is the DAppNode package `searxng-lan.public.dappnode.eth`: SearXNG behind a Caddy gateway that only answers
home-network addresses. Read `README.md` first: it covers the user view, the architecture and the dev commands.
This file adds what an agent and the maintainer need on top: the rules, every action with its procedure (including
releases), and the traps already hit.

## Rules

- **Keys and transactions belong to the maintainer.** Never ask for, hold or handle a private key or seed phrase, and
  never send a transaction. The maintainer is publisher `0x3211695ED0b0c277E7340dA9A6ED025463774797` (`cperezz.eth`).
  He signs twice per release, in his own wallet:
  - the release message, through `tools/sign.html`;
  - the publish transaction, on the sdk-publish page.

  You prepare both and verify the results.
- **Simulate before he signs the publish transaction.** Show him the decoded calldata, plus an `eth_call` and a gas
  estimate from his DAppNode's execution client, with the cost in ETH and USD (see "Simulate the publish
  transaction").
- **This repo and its releases are public.** Nothing about the maintainer's own setup goes into them: no real IPs, no
  ports he chose, no hostnames, usernames or local paths, no other packages he runs.
  - Examples use `dappnode.local:8080`, `<your DAppNode's IP>` and documentation ranges (`192.0.2.0/24`,
    `198.18.0.0/24`).
  - `tools/leakcheck.sh` enforces this. Its pattern file (`~/.config/searxng-lan/leak-patterns.txt` on the
    maintainer's workstation) is personal data. Never copy it into the repo, print it, or quote its contents in a
    commit, issue or PR.
- **Secrets.** Never print the SearXNG secret key, or the containers' environment (`docker inspect`, `env`). Compare
  the key by fingerprint only, as `tools/verify.sh` does.
- **On the DAppNode host:**
  - Never run `ipfs repo gc`. It deletes unpinned releases and other packages' data.
  - Never write inside the dappmanager container. Running its image in a throwaway container, to read or run its
    code, is fine.
  - Never reboot the host or touch router/UPnP settings.
  - Don't install, update or uninstall the maintainer's packages yourself. Hand him the installer link, and verify
    afterwards.
- **Git.** `main` is the only long-lived branch. Commits use the maintainer's GitHub noreply address, from repo-local
  config. Run `tools/leakcheck.sh all` before every push.

## Layout

| Path | Role |
|---|---|
| `dappnode_package.json` | Manifest: name, version, upstream SearXNG version, links (homepage only, see traps) |
| `docker-compose.yml` | `gateway` (Caddy, the only published port, `8080:8080`) and `searxng`; pinned `CADDY_VERSION` / `SEARXNG_VERSION` build args; volume `searxng-data` |
| `setup-wizard.yml` | Install form: port, `ALLOWED_NETWORKS` (gateway), `OUTGOING_PROXY` (searxng) |
| `gateway/` | Caddy allowlist: 403 outside `ALLOWED_NETWORKS` and for Docker-relayed sources (bridge gateways) |
| `searxng/` | Official image + `settings.yml` (overrides only, `use_default_settings: true`) + entrypoint (per-install secret in `/var/cache/searxng/secret_key`, optional proxy) |
| `dev/compose.override.yml` | Dev stack on a DAppNode host (project `sx-dev`, port 18080) |
| `dev/compose.ci.yml` | CI stack on a plain Docker host (project `sx-ci`, port 8080) |
| `tools/verify.sh`, `tools/probe.py` | Automated checks of every package property |
| `tools/lan-check.sh` | Check from a laptop on the home network: page and OpenSearch on both addresses |
| `tools/leakcheck.sh` | Scanner for maintainer-specific strings (tree, history, built release) |
| `tools/sign-release.mjs`, `tools/sign.html`, `tools/package.json` | Release signing in dappmanager's exact format |
| `.github/workflows/` | `ci.yml` (every push/PR), `bump.yml` (weekly SearXNG PR), `release.yml` (GitHub release on `v*` tag) |
| `docs/` | README screenshots |

## Where things run

- **The maintainer's workstation** runs git, `gh`, `cast` (Foundry) and `tools/lan-check.sh`.
- **The DAppNode host, over SSH,** runs everything that needs DAppNode's Docker networks (`dncore_network`), IPFS
  (`http://ipfs.dappnode:5001`) or the execution client. That covers the dev stack, `verify.sh`, the build and the
  signing tools.
- The host has neither git nor rsync. Sync the working tree with tar:
  `COPYFILE_DISABLE=1 tar --exclude .git -cf - . | ssh <host> 'tar -C <repo-dir> -xf -'`.
- SSH sessions drop, so detach long jobs on the host and read the log afterwards:
  `setsid -f sh -c 'cmd > /tmp/x.log 2>&1; echo EXIT=$? >> /tmp/x.log'`.

## Actions

### Change settings, engines or the gateway

1. Edit `searxng/settings.yml`, `gateway/Caddyfile` or the entrypoints. Settings are baked into the image and
   re-applied on every start; only the secret key persists.
2. Bring up the dev stack and run `tools/verify.sh all`. Every line must PASS.
3. Shipping the change to users means a new version (see "Release").

Engines: upstream defaults plus Bing and Yahoo. Google's direct engine ("access denied") and Qwant (CAPTCHA) fail from
residential IPs, so they stay disabled.

### Dev loop (DAppNode host, repo dir)

```sh
docker compose -p sx-dev -f docker-compose.yml -f dev/compose.override.yml up -d --build
tools/verify.sh            # = all; TARGET=dev
docker compose -p sx-dev -f docker-compose.yml -f dev/compose.override.yml down -v
```

### Test suites

- `tools/verify.sh all|quick`, with `TARGET=dev|ci|package`. For `TARGET=package`, set `PORT` to the installed
  package's host port.
  - `quick` is the CI subset, with no live searches.
  - `all` covers image pins, the install-form protocol, the 403 rules, engines, image proxy, defaults, the
    per-install secret (HMAC use, persistence across restarts) and container hardening.
- Live engine checks can flake when an engine rate-limits. Rerun once before debugging.
- `tools/lan-check.sh <dappnode-ip> <port>` runs from a laptop on the home network.
- An agent can't test from outside. The 403 from the internet (phone on mobile data, `http://<public-ip>:<port>`) is
  the maintainer's check.

### Bump SearXNG or Caddy

- **SearXNG.** `bump.yml` runs on Mondays (or `gh workflow run bump.yml`). It picks the newest dated Docker Hub tag,
  rewrites `docker-compose.yml` and `dappnode_package.json`, force-pushes branch `bump-searxng`, opens or updates the
  PR, and dispatches CI on that branch. PRs opened with `GITHUB_TOKEN` don't trigger CI by themselves, which is why
  it dispatches.
  - Merge once CI is green and a dev-stack `verify.sh all` passes on the host.
  - Then release a patch version.
- **Caddy** has no bot. Edit `CADDY_VERSION` in `docker-compose.yml` by hand, then follow the same checks.

### Build and test-install by hash

1. On the host, run the build command from README "Development". It prints the release hash and leaves
   `build_searxng-lan.public.dappnode.eth_<version>/` behind (files mode 600, owned by the host user). It also leaves
   the `dappnode-multiarch-builder` buildx builder running.
2. The maintainer installs or updates by opening
   `http://dappnode.local/installer/public/%2Fipfs%2F<hash>`.
   - An unsigned release shows a "bypass" checkbox.
   - A release signed with his key shows as trusted, once he has added the key under System → Advanced → Release
     trusted keys.
3. Then run `TARGET=package PORT=<port> tools/verify.sh`. Never publish a release that hasn't been installed and has
   passed this suite.

### Leak checks

- **On the workstation, before each push:** `tools/leakcheck.sh all`. It covers the tree and the history, including
  author emails. `staged` scans only staged changes.
- **On the host, after the build:** `tools/leakcheck.sh release build_searxng-lan.public.dappnode.eth_<version>`.
  1. Copy the pattern file there temporarily (mode 600) and point `SXLAN_LEAK_PATTERNS` at it.
  2. Run the scan. It covers the metadata files, each image's config and the four files our Dockerfiles copy in. It
     skips upstream base layers, which match common strings by coincidence.
  3. Delete the copy afterwards.

### Release (publish a new version)

Every published version is one mainnet transaction from the publisher, who owns the package name. The maintainer makes
the two signatures (steps 4 and 7); the agent prepares and verifies everything around them.

1. **Version.** Merge any pending SearXNG bump PR. Raise `version` in `dappnode_package.json`. The on-chain repo only
   accepts a bump of exactly one of major/minor/patch by 1, with the lower parts reset to 0. Commit and push once
   `tools/leakcheck.sh all` is clean.
2. **Build, install by hash and run the suite** (above). The build prints the **unsigned** release hash. Then run
   the release leakcheck.
3. **Message.** On the host:
   ```sh
   mkdir -p /tmp/sign && cp tools/sign-release.mjs tools/package.json tools/sign.html /tmp/sign/
   docker run --rm --network dncore_network -v /tmp/sign:/app -w /app node:22-alpine sh -c \
     "npm install --no-audit --no-fund >/dev/null 2>&1 && node sign-release.mjs message <unsigned-hash> > message.txt"
   ```
   It holds one `file cid` line per release file, sorted, without `signature.json`, in dappmanager's exact format.
4. **The maintainer signs.**
   - Copy `sign.html` and `message.txt` from `/tmp/sign` to his workstation and serve them there with
     `python3 -m http.server 8765 --bind 127.0.0.1`. Wallet extensions don't inject into `file://`.
   - Give him `http://127.0.0.1:8765/sign.html?address=0x3211695ED0b0c277E7340dA9A6ED025463774797`. He clicks *Sign
     with my wallet*.
   - Tell him what he signs: the wallet shows the same lines as a plain `personal_sign` (no transaction, no gas).
   - He pastes the signature back.
5. **Check and assemble.**
   1. Locally: `cast wallet verify --address <publisher> "$(cat message.txt)" <sig>`.
   2. On the host:
      ```sh
      docker run --rm --network dncore_network -v /tmp/sign:/app -w /app node:22-alpine \
        node sign-release.mjs assemble <unsigned-hash> <signature>      # prints the signed hash
      docker run --rm --network dncore_network -v /tmp/sign:/app -w /app node:22-alpine \
        node sign-release.mjs verify <signed-hash> <publisher>          # must print the publisher address
      ```
      `assemble` adds `signature.json`, uploads the new folder and pins it.
   3. Verify with dappmanager's own code too. Run its image in a throwaway container, from
      `/usr/src/app/packages/toolkit`, with this `.mjs`:
      ```js
      import { CID } from "multiformats/cid";
      import { serializeIpfsDirectory, getReleaseSigningKey } from "./dist/repository/releaseSignature.js";
      const api = (p) => fetch(`http://ipfs.dappnode:5001/api/v0/${p}`, { method: "POST" });
      const ls = await (await api(`ls?arg=${process.argv[2]}`)).json();
      const files = ls.Objects[0].Links.map((l) => ({ name: l.Name, cid: CID.parse(l.Hash) }));
      const sig = JSON.parse(await (await api(`cat?arg=${files.find((f) => f.name === "signature.json").cid}`)).text());
      console.log(getReleaseSigningKey(serializeIpfsDirectory(files, sig.cid), sig.signature, sig.signature_protocol));
      ```
      Pipe it in (`docker run --rm -i --network dncore_network --entrypoint sh <dappmanager-image> -c 'cd
      /usr/src/app/packages/toolkit && cat > v.mjs && node v.mjs <signed-hash>' < v.mjs`). It must print the
      publisher address.
6. **Update test.** The maintainer updates his install to the signed hash (by-hash link). Expect: trusted, no bypass
   checkbox, port kept. Then run the package suite and confirm the secret fingerprint is unchanged.
7. **Simulate, then the maintainer publishes.**
   1. Simulate (next section) and show him the decoded call, the gas and the cost.
   2. He opens
      `https://dappnode.github.io/sdk-publish/?r=searxng-lan.public.dappnode.eth&v=<version>&d=<publisher>&h=/ipfs/<signed-hash>`
      and connects the publisher wallet; the form only appears after he connects.
   3. Before sending, he checks the target contract, function, value 0 and hash in the wallet.
   4. He gives you the transaction hash.
8. **After the transaction is mined,** verify it (see "After publishing"), then tag and push:
   `git tag v<version> && git push origin v<version>`. `release.yml` creates the GitHub release.
9. **Clean up on the host.** `/tmp/sign` holds root-owned files, so remove it with
   `docker run --rm -v /tmp:/t alpine:3.22 rm -rf /t/sign`. Delete the build dir and any copied pattern file.

### Simulate the publish transaction

Use the host's execution client. From the workstation, forward it: `ssh -O forward -L
127.0.0.1:18545:<el-container-ip>:8545 <host>` (find the IP with `docker inspect` on the EL container's
`dncore_network`). Containers on `dncore_network` can reach it as `http://execution.mainnet.dncore.dappnode:8545`.
Check it's synced (`eth_syncing` false, block number equal to a public RPC's). Fall back to
`https://ethereum-rpc.publicnode.com`.

```sh
RPC=http://127.0.0.1:18545; DEV=0x3211695ED0b0c277E7340dA9A6ED025463774797
Z=0x0000000000000000000000000000000000000000; URI=$(cast --from-utf8 /ipfs/<signed-hash>)
REPO=$(cast resolve-name searxng-lan.public.dappnode.eth --rpc-url $RPC)
cast call $REPO "getLatest()(uint16[3],address,bytes)" --rpc-url $RPC        # current version and content
DATA=$(cast calldata "newVersion(uint16[3],address,bytes)" "[0,1,1]" $Z $URI)
cast calldata-decode "newVersion(uint16[3],address,bytes)" $DATA            # show him; bytes = /ipfs/<signed-hash>
cast call --from $DEV $REPO $DATA --rpc-url $RPC                            # must not revert
cast estimate --from $DEV $REPO $DATA --rpc-url $RPC                        # ~207k gas
cast base-fee --rpc-url $RPC
cast call 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 "latestAnswer()(int256)" --rpc-url $RPC   # ETH/USD, 8 decimals
```

- **The wallet must show** `to` = `$REPO`, function `newVersion`, value 0, sender the publisher.
- **The first version is different.** It was `newRepoWithVersion("searxng-lan", <publisher>, [0,1,0], 0x0, bytes)`
  on the `public.dappnode.eth` registry, `0x9F85AE5aeFE4a3eFF39d9A44212aae21Dd15079A`, at ~942k gas. That repo now
  exists, so every later release uses `newVersion` on the repo.

### After publishing

- `cast resolve-name searxng-lan.public.dappnode.eth` returns the repo.
- `getLatest()` returns the new version and the signed hash.
- `cast tx <hash> from` is the publisher.
- The `Release` workflow run is green, and `gh release view v<version>` shows the hash.
- If the maintainer hasn't enabled auto-updates, he updates from the package page. Rerun the package suite.
- Releases are pinned only on the maintainer's DAppNode IPFS. Its update daemon checks installed packages by name
  and version (`daemons/dist/autoUpdates/updateMyPackages.js`, origin is ignored). When it sees a newer version, it
  pins the new release and **unpins the previous one**. After that, older versions survive only until IPFS garbage
  collection. To keep an old version installable by hash, re-pin it (`ipfs pin add`; never `repo gc`).

## Traps already hit

- **The `setup-wizard.yml` port target must name the protocol** (`containerPort: "8080/TCP"`). The admin UI keys the
  answer verbatim, while dappmanager looks it up as `<container>/<PROTOCOL>`. A bare `"8080"` is silently ignored, so
  the install keeps 8080. `verify.sh` checks this.
- **No `links.ui` in the manifest.** DAppNode shows manifest links verbatim, with no port substitution, so a fixed URL
  is wrong for anyone who picked another port.
- **DAppNode UPnP-forwards every published port to the internet.** Only the gateway may publish a port, and it must
  keep answering 403 outside `ALLOWED_NETWORKS`.
- **Docker relays IPv6 and loopback clients from its bridge gateway address,** which hides the real client. The
  gateway refuses those sources. Users who get a 403 on `dappnode.local` (IPv6) should use the IPv4 address.
- **A port conflict** fails the install with Docker's "port is already allocated", and dappmanager rolls back
  cleanly. The README tells users to pick another port.
- **Caddy's file capability** (`cap_net_bind_service`) breaks under `cap_drop: ALL` + `no-new-privileges`. It's
  stripped in a `FROM --platform=$BUILDPLATFORM` stage. Every other Dockerfile step is COPY-only, so arm64 builds need
  no emulation.
- **Default trusted release keys** for `.public.dappnode.eth` are only DAppNode's and Nethermind's. Other users see
  this package as signed by an unknown key unless they add the maintainer's.
- **Unpacked image layers contain read-only directories.** Run `chmod -R u+w` before `rm -rf`, as `leakcheck.sh`
  does.
- **DAppNode's networks:** `dncore_network` is `172.33.0.0/16`, the OpenVPN pool `172.33.8.0/22`, WireGuard
  `10.24.0.0/24`. The default `ALLOWED_NETWORKS` covers all of them. VPN access is untested.
