# Artemis feedback server

A Cloudflare Worker behind `POST https://feedback.artemisbrowser.app/v1/reports`. Feedback from the app becomes an issue in a private repo, with screenshots committed under `attachments/YYYY/MM/`. Errors and crashes get one issue per signature: a repeat from a build already filed changes nothing, and each new build adds one comment and reopens the issue unless it was closed as not planned. A retried report keeps its id, so it neither files twice nor commits its screenshots again. Report bodies are never logged. `npm test` runs the tests (Node 22 or later, nothing to install).

## One-time setup, from this folder

1. `gh repo create devfindles/artemis-feedback --private --add-readme` (never the app's repo, which may go public).
2. `for l in feedback bug idea other error crash; do gh label create $l -R devfindles/artemis-feedback --force; done`
3. At https://github.com/settings/personal-access-tokens/new, make a fine-grained token for `devfindles/artemis-feedback` only, with Contents and Issues set to read and write. The form defaults to 30 days: pick the longest expiration it offers and note the date. An expired token turns every report into a 502 (the log shows `github POST /issues 401`); renew it by making a new token the same way and repeating step 6.
4. `npm i -D wrangler && npx wrangler login`
5. `npx wrangler kv namespace create SIGS`, then paste the printed id into `wrangler.jsonc`.
6. `npx wrangler secret put GITHUB_TOKEN`, then paste the token.
7. `npx wrangler deploy` (artemisbrowser.app has to be a zone on the same Cloudflare account).
8. Smoke test; expect `201` and a new issue:
   ```sh
   curl -i https://feedback.artemisbrowser.app/v1/reports -H 'content-type: application/json' \
     -d '{"kind":"feedback","install":"00000000-0000-4000-8000-000000000000","app":{"version":"0","build":"0"},"os":"curl","model":"curl","arch":"arm64","feedback":{"category":"other","message":"Smoke test"}}'
   ```
