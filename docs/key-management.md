# Key management and rotation

## Key classes

Scout uses five separate secret classes:

| Secret | Lifetime | Holder | Purpose |
| --- | --- | --- | --- |
| OpenAI API key | persistent, revocable | Keychain and Gateway process | Provider authorization |
| Approval HMAC keyring | persistent, rotatable | Keychain, Gateway, read-only MCP verifier | Authenticate approved context packs |
| Gateway bearer | one launch | launcher, Gateway, Scout UI | Authorize native REST/WebSocket traffic |
| Approval token | one launch | launcher, Gateway, Scout UI | Separate operator-approval capability |
| Event-store encryption key | device-local persistent | app Keychain and persistence cipher | Encrypt append-only journal bodies |

The app process never receives the OpenAI key or approval HMAC keyring. It receives only ephemeral
Gateway and approval tokens. No secret is serialized into an event, context pack, log, SBOM, release
manifest, or Codex prompt.

## Storage

The native launcher stores Gateway secrets as non-synchronizing generic-password items with
`AfterFirstUnlockThisDeviceOnly` accessibility. The OpenAI key and JSON approval keyring use distinct
accounts. A keyring contains one active signer and up to 31 retained verification keys.

The sandboxed UI separately owns the event-store encryption key. It is device-bound, non-synchronizing,
and currently has no export, backup, or rotation path. Loss of that Keychain item makes the encrypted
journal unrecoverable; this is deliberate fail-closed behavior until per-engagement keys exist.

Development uses the base Keychain service. Packaged ad-hoc builds receive a random namespace to avoid
silently inheriting secrets from a differently signed executable. Developer ID releases use the stable
`release-v1` namespace so updates signed by the same identity can retain access.

## Initial migration

```sh
cp .env.example .env.local
# Add OPENAI_API_KEY once.
make configure-secrets
```

Legacy `SCOUT_APPROVAL_HMAC_KEY` and `SCOUT_APPROVAL_KEY_ID` values are preserved if present. The
migration sends secret JSON only over a child-process stdin pipe and removes all recognized secret
lines from `.env.local` after Keychain confirms the import. If Keychain import fails, the command leaves
`.env.local` untouched; fix Keychain access, rerun migration, then verify that secret lines are absent.

## Packaged provisioning

After an ad-hoc or signed package is assembled locally:

```sh
make provision-package
```

The script reads the development secret contract from the development launcher and sends it over stdin
to the packaged executable. It verifies only non-secret status fields. It never prints or writes the
secret values.

For a distributed release installed in `/Applications`, configure the provider key through the same
signed launcher binary without placing it in argv, shell history, or a file:

```sh
/Applications/Scout.app/Contents/MacOS/Scout secrets configure-openai
```

The command requires an interactive terminal and hides input. It also creates the first approval key
when the release namespace is empty. Do not ship a pre-provisioned Keychain, `.env.local`, or
environment export.

## Approval rotation

```sh
make rotate-approval-key
```

Development rotation generates a new random active key and key ID, retains prior keys as verify-only,
and never rewrites approved packs. New packs use the new key; old packs remain readable because verification
selects the key named in their immutable approval binding.

The keyring holds at most 32 keys total. Rotation fails closed at that limit; inventory, reapprove or
expire affected packs, then retire a verify-only key before trying again.

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
7. Revoke the verify-only key with an explicit invalidation acknowledgement:

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
