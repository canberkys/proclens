# ProcLens feedback relay

A tiny Cloudflare Worker that lets the ProcLens app submit bug reports/feature
requests as real GitHub issues without redirecting the user out to mail or a
browser, and without ever putting a GitHub token inside the shipped app.

## How it works

`ProcLens/Features/Feedback/FeedbackClient.swift` POSTs `{type, title, description,
diagnostics}` to this Worker's URL, with an `X-ProcLens-Client` header (a
constant baked into the app — not real auth, just filters out drive-by
hits). The Worker validates the payload and creates an issue in
`canberkys/proclens` using a GitHub PAT that lives only as a Worker secret.

## One-time setup (do this once, manually)

1. **Cloudflare**: have (or create) a Cloudflare account, then authenticate
   the CLI locally:
   ```
   cd feedback-relay
   npx wrangler login
   ```
   This opens a browser OAuth flow — has to be done interactively, by you.

2. **GitHub PAT**: github.com/settings/tokens → *Fine-grained tokens* → New
   token → **Repository access: only `canberkys/proclens`** → **Permissions:
   Issues → Read and write** (nothing else). Copy the token — you'll paste
   it once into the `wrangler secret put` prompt below, never into a chat
   or a file.

3. **Deploy**, then set both secrets (each prompts for a value, typed/pasted
   directly into the terminal — never stored in this repo):
   ```
   npx wrangler deploy
   npx wrangler secret put GITHUB_PAT
   npx wrangler secret put CLIENT_TOKEN
   ```
   `CLIENT_TOKEN` can be any random string — generate one with
   `openssl rand -hex 32`. Whatever value you set here must exactly match
   the constant baked into `FeedbackClient.swift` (`FeedbackClient.clientToken`).

4. Deploy prints the Worker's URL (`https://proclens-feedback-relay.<your
   subdomain>.workers.dev`) — that's what `FeedbackClient.swift`'s
   `FeedbackClient.relayURL` needs to point at.

## Redeploying after a code change

```
cd feedback-relay
npx wrangler deploy
```
Secrets persist across deploys — no need to re-set them unless rotating.

## Testing

```
curl -X POST https://<worker-url> \
  -H "X-ProcLens-Client: <CLIENT_TOKEN value>" \
  -H "Content-Type: application/json" \
  -d '{"type":"bug","title":"Test issue — delete me","description":"Verifying the relay end to end."}'
```
Confirm a real issue appears at github.com/canberkys/proclens/issues, then
delete/close it — this is a live write to the real repo, not a sandbox.
