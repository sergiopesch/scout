# Key management and rotation

## Key classes

Scout uses five separate secret classes:

| Secret | Lifetime | Holder | Purpose |
| --- | --- | --- | --- |
| OpenAI API key | persistent, revocable | Keychain and Gateway process | Provider authorization |
| Approval Ed25519 signer | persistent, rotatable | Keychain and Gateway process | Sign approved context packs |
| Approval public keyring | persistent, versioned | Application Support, Gateway, MCP process | Verify approved context packs |
| Gateway bearer | one launch | launcher, Gateway, Scout UI | Authorize native REST/WebSocket traffic |
| Approval token | one launch | launcher, Gateway, Scout UI | Separate operator-approval capability |
| Event-store encryption key | device-local persistent | app Keychain and persistence cipher | Encrypt append-only journal bodies |

The app process never receives the OpenAI key or approval private keyring. It receives only ephemeral
Gateway and approval tokens. No secret is serialized into an event, context pack, log, SBOM, release
manifest, or Codex prompt.

The bundled MCP process does not query Keychain or invoke a launcher secret-export command. The
launcher publishes `approval-public-keyring-v1.json` under Scout Application Support with owner-only
permissions. It contains only Ed25519 public keys, generation metadata, and revoked key IDs. The MCP
can verify the exact approval binding but cannot derive the private seed or mint an approval. Missing,
malformed, or revoked keys fail approved reads closed.

## Storage

The native launcher stores Gateway secrets as non-synchronizing generic-password items with
`AfterFirstUnlockThisDeviceOnly` accessibility. The OpenAI key and JSON approval keyring use distinct
accounts. A keyring contains one active Ed25519 private seed, up to 31 retained public compatibility
keys, and a bounded revoked-ID history. Rotation removes the former private seed before the new signer
becomes active; revocation removes its public key and frees a compatibility slot. The public keyring is
rebuildable output, not secret or signing authority.

The sandboxed UI separately owns the event-store encryption key. It is device-bound, non-synchronizing,
and currently has no export, backup, or rotation path. Loss of that Keychain item makes the encrypted
journal unrecoverable; this is deliberate fail-closed behavior until per-engagement keys exist.

Development uses the base Keychain service and a machine-local Apple Development identity configured
with `make configure-development-signing`. The normal `make run` path refuses ad-hoc UI signing: an
ad-hoc app's designated requirement collapses to its changing code hash, so macOS cannot recognize
successive builds as the same trusted application. Each authorised collaborator creates their own
development certificate and device-local event key; private signing identities and Keychain secrets
are never copied between maintainers. Packaged ad-hoc builds receive a random namespace to avoid
silently inheriting secrets from a differently signed executable. Developer ID releases use the stable
`release-v1` namespace so updates signed by the same identity can retain access.

If a Mac already created `dev.scout.discovery.event-store` under an older ad-hoc build, its first
Apple Development-signed launch can show one final Keychain migration prompt. Enter the login password
and choose **Always Allow** so the existing encrypted journal remains readable. Do not delete or
recreate that item merely to avoid the prompt: the current journal has no key export or recovery path.

## Initial migration

```sh
cp .env.example .env.local
# Add OPENAI_API_KEY once.
make configure-secrets
```

Legacy HMAC variables are removed from `.env.local` but are not migrated into the Ed25519 keyring.
Existing HMAC-approved packs therefore fail closed and require explicit restaging and reapproval.
Device-owner authentication is required before the developer helper imports or exports any secret. The
migration sends secret JSON only over a child-process stdin pipe and removes all recognized secret
lines from `.env.local` after Keychain confirms the import. If Keychain import fails, the command leaves
`.env.local` untouched; fix Keychain access, rerun migration, then verify that secret lines are absent.

## Packaged provisioning

After an ad-hoc validation package is assembled locally:

```sh
make provision-package
```

The script requests device-owner authentication for the development read and ad-hoc import, captures
the development secret contract over a child-process pipe, and sends it over stdin to the ad-hoc
executable. It verifies only non-secret status fields. It never prints or writes the secret values.
Developer ID launchers do not compile plaintext secret export or import commands.

For a distributed release installed in `/Applications`, configure the provider key through the same
signed launcher binary without placing it in argv, shell history, or a file:

```sh
/Applications/Scout.app/Contents/MacOS/Scout secrets configure-openai
```

The command requires an interactive terminal, a fresh device-owner authentication, and hidden input. It
also creates the first approval key when the release namespace is empty. Rotation and revocation
commands require the same local authentication. Do not ship a pre-provisioned Keychain, `.env.local`,
or environment export.

## Approval rotation

```sh
make rotate-approval-key
```

Development rotation generates a new random Ed25519 private seed and key ID, deletes the old private
seed, retains its public key as a compatibility entry, republishes verification state, and never
rewrites approved packs. New packs use the new key; old packs remain readable because verification
selects the public key named in their immutable approval binding.

The keyring holds at most 32 keys total. Rotation fails closed at that limit; inventory, reapprove or
expire affected packs, then retire a retained key before trying again.

To rotate the installed release namespace, invoke its signed executable:

```sh
/Applications/Scout.app/Contents/MacOS/Scout secrets rotate-approval
```

Before retiring an old verification key:

1. Stop Scout and any Codex task using the Scout MCP process so no verifier retains an old keyring in
   memory.
2. Inventory packaged approved packs by signing key without exposing customer content:

   ```sh
   /Applications/Scout.app/Contents/MacOS/Scout secrets approval-key-usage
   ```

3. Re-stage and explicitly reapprove any pack that must remain accessible.
4. Archive or delete packs whose retention period ended under the customer policy.
5. Stop Scout and every Scout MCP process again after reapproval so no verifier retains the old
   startup keyring.
6. Run the usage command again and verify no retained pack references the old key ID.
7. Revoke the retained key with an explicit invalidation acknowledgement:

   ```sh
   /Applications/Scout.app/Contents/MacOS/Scout \
     secrets revoke-approval OLD_KEY_ID --confirm-invalidates-packs
   ```

Revocation affects every verifier started afterward: packs signed only by that key stop passing
approved reads. A Gateway or MCP process already running retains its startup keyring, which is why the
stop/relaunch step is mandatory. The active key cannot be revoked; rotate first. Accidental revocation
is a data-availability event and the command has no automatic rollback.

## Provider-key rotation

1. Create a new project-scoped OpenAI key with the minimum required access.
2. Replace it through the installed app's hidden terminal prompt:

   ```sh
   /Applications/Scout.app/Contents/MacOS/Scout secrets configure-openai
   ```
3. Run packaged smoke and live smoke.
4. Revoke the old key in the OpenAI Platform.
5. Confirm no CI secret, shell history, log, or `.env.local` copy remains.

Provider-key rotation does not affect approved pack authenticity because approval uses an independent
local keyring.

## Compromise response

- Provider key suspected: stop Gateway, rotate/revoke the provider key, review OpenAI project usage,
  then run smoke verification.
- Approval key suspected: stop Scout and every Scout MCP process, record the compromised key ID,
  rotate, revoke that former key, then relaunch. Treat affected packs as unavailable until explicitly
  reapproved and preserve the event journal for audit.
- Ephemeral token suspected: terminate the supervised pair. Relaunching creates unrelated credentials
  and port identity.
- Device compromise: Keychain and device-bound encryption cannot protect against an active root-level
  attacker. Stop using the device and follow organizational incident response.
