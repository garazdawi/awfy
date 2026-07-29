<!-- SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org> -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# #75 shared-heap — patched-MongooseIM MUC fan-out A/B on the XMPP rig

Goal: run MongooseIM 6.6.0 on a share-enabled OTP (`erts_debug:share/1` +
`reclaim_shared/0`) with the MUC-light broadcast sharing the groupchat payload, and
A/B it (share off vs on) under a MUC fan-out Amoc load, on GHA. Off/on is a **runtime
flag** (`-share_muc true`) on one image, so a single build measures both arms.

## Done + verified (staged in this repo)

- **`patches/otp/share-reclaim-27.3.patch`** — the share/reclaim BIF patch. `git apply`
  clean on the `OTP-27.3` tag. Adds `erts_debug:share/1`, `reclaim_shared/0`,
  `shared_info/0` (copy-out reclamation via the literal-area collector). Proven on an
  OTP-27.0.1 build: no leak (74 MB → baseline), held terms survive copy-out.
- **`patches/mongooseim-6.6.0/01-muc-light-share-reclaim.patch`** — hooks
  `mod_muc_light_codec_modern:encode/5` (the `#msg` fan-out at the `lists:foreach` over
  `AffUsers`) to `erts_debug:share/1` the payload once when started `-share_muc true`,
  and `reclaim_shared/0` every 500 messages. `patch -p1` clean on the 6.6.0 tarball.
  Zero overhead when disabled (one `persistent_term` read).

## Remaining wiring (4 steps)

### 1. Build the patched OTP image (OTP-injection point = `MIM_BASE_IMAGE`)

Copy the "Build … base image" step from `.github/workflows/sih-xmpp.yml`, but clone the
`OTP-27.3` **tag** (read-only, from erlang/otp or garazdawi/otp) and apply the patch.
Critically, **recompile `erts_debug.beam` without `+deterministic`** after `make install`
— the kernel build compiles it `+debug_info +deterministic`, which for the patched source
produces a "corrupt atom table" beam (a narrow compiler edge; see the otp-ideas
`RECLAMATION.md`). Dockerfile sketch:

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libssl-dev libncurses-dev m4 perl git autoconf ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch OTP-27.3 https://github.com/erlang/otp /otp
WORKDIR /otp
COPY share-reclaim-27.3.patch /tmp/p.patch
RUN git apply /tmp/p.patch
RUN ./configure --prefix=/usr/local --without-wx --without-debugger --without-observer \
      --without-et --without-megaco --without-jinterface \
    && make -j"$(nproc)" && make install
# fix the deterministic-compiled erts_debug.beam (see RECLAMATION.md gotcha)
RUN /usr/local/bin/erlc +debug_info -o "$(dirname $(find /usr/local/lib/erlang -name erts_debug.beam -path '*kernel*'))" \
      /otp/lib/kernel/src/erts_debug.erl
RUN erl -noshell -eval 'S=erts_debug:share({a,b,[1,2,3]}), {N,_}=erts_debug:shared_info(), \
      erts_debug:reclaim_shared(), io:format("SHARE_OK ~p ~p~n",[S=={a,b,[1,2,3]},N]), halt().'
```
Build context must include `share-reclaim-27.3.patch` (copy it in the workflow step, as
sih-xmpp does with its heredoc). Tag e.g. `otp-shared:27-local`. Then in the run step set
`MIM_BASE_IMAGE=otp-shared:27-local`, `MIM_RUNTIME_IMAGE=otp-shared:27-local`,
`MIM_OTP_VERSION=27.3`.

### 2. Enable mod_muc_light on the broker

`priv/topology/mongooseim-6.6.0-prod.vars-toml.config` has `{mod_X, ""}` vars filling
`{{{mod_X}}}` template placeholders — but the 6.6.0 template has **no `{{{mod_muc_light}}}`
placeholder** (only amp/blocking/cache_users/last/offline/privacy/private/roster/vcard).
So either (a) add a second file-diff to `patches/mongooseim-6.6.0/` that inserts
`{{{mod_muc_light}}}` into `rel/files/mongooseim.toml`'s modules block AND set a
`{mod_muc_light, "[modules.mod_muc_light]\n  backend = \"rdbms\""}` var, or (b) simpler:
patch the toml template to inline `[modules.mod_muc_light]\n  backend = "rdbms"` directly.
The `muc_light_*` tables already exist in `priv/topology/mongooseim-6.6.0-pg.sql`, so
`backend = "rdbms"` works. MUC-light domain = `muclight.localhost` (matches the Amoc
`muc_light_prefix` default `<<"muclight">>` with host_type `localhost`).

### 3. Scenario config + Amoc MUC knobs

- Add `priv/scenario-config/dynamic_domains_muc_light.local.json` — copy
  `dynamic_domains_pm.local.json` (the `ScenarioConfig` `@enforce_keys` are PM-shaped and
  required), set `"scenario": "dynamic_domains_muc_light"`, keep `users` (2nd arg to
  `amoc_dist:do/3`).
- The MUC knobs come from **`AMOC_*` env on the `amoc-worker` service** in
  `priv/topology/local.compose.yml` (mirror the existing `AMOC_MESSAGE_COUNT` block), not
  the json: `AMOC_USERS_PER_ROOM` (**fan-out width — the key knob, default 5, set higher
  e.g. 20-50**), `AMOC_ROOMS_PER_USER`, `AMOC_MESSAGES_SENT_PER_ROOM`,
  `AMOC_ROOM_MESSAGE_INTERVAL`, `AMOC_ROOM_CREATION_INTERVAL`,
  `AMOC_DELAY_BEFORE_CREATING_ROOMS`, `AMOC_DELAY_BEFORE_SENDING_MESSAGES`,
  `AMOC_DELAY_AFTER_SENDING_MESSAGES`, and `AMOC_MESSAGE_BODY` (**payload size — make it
  a few KB of text so the copy tax is real; big binaries are already refc-shared**).
  The scenario `dynamic_domains_muc_light` already exists in the pinned
  amoc-arsenal-xmpp (`src/scenarios/dynamic_domains_muc_light.erl`).

### 4. Workflow (clone sih-xmpp.yml)

New `.github/workflows/share-xmpp.yml` = `sih-xmpp.yml` with: the OTP build from §1;
`MIM_*` from §1; the A/B loop toggling `MIM_ERL_FLAGS="-share_muc false"` vs `"true"`
(interleaved reps) instead of `+sih`; `--scenario dynamic_domains_muc_light`. Primary
metrics come free from `Awfy.Xmpp.Runner` (docker-stats CPU/mem summed across brokers +
amoc `messages_sent` throughput). Expected: share-on lowers per-message CPU + broker
memory highwater at higher `AMOC_USERS_PER_ROOM`, matching the pattern benchmark's
2.1–2.4× fan-out win. Optionally extend `priv/heap_probe/heap_probe.erl` +
`census_xmpp.escript` with a `shared_info` reader for term-level A/B.

## Trigger

`gh workflow run share-xmpp.yml -f scenario=dynamic_domains_muc_light` (on origin/awfy).
First run will likely need 1–2 config iterations (mongoose toml / scenario knobs).
