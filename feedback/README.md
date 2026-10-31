# Artemis feedback server

A Cloudflare Worker behind `POST https://feedback.artemisbrowser.app/v1/reports`.

- **Feedback** becomes a public issue on `PUBLIC_REPO` holding only the message, the category and the app and macOS versions, labelled `from-app`. The reply hands the app its URL so the sender can follow it. Unless the sender ticked "Keep this private", which files nothing public.
- **Everything else** goes to a private issue on `PRIVATE_REPO`, linked to the public one: email, page address, screenshots (committed under `attachments/YYYY/MM/`), diagnostics.
- **Errors and crashes** stay private, one issue per signature. A repeat from a build already filed changes nothing; each new build adds one comment and reopens the issue unless it was closed as not planned.
- A retried report keeps its id, so it neither files twice nor commits its screenshots again. Report bodies are never logged.
- `npm test` runs the tests (Node 22 or later, nothing to install).

## One-time setup, from this folder

1. `gh repo create artemisbrowser/artemis-feedback --private --add-readme`
2. Labels:
   ```sh
   for l in feedback bug idea other error crash public; do gh label create $l -R artemisbrowser/artemis-feedback --force; done
   for l in from-app bug idea other; do gh label create $l -R artemisbrowser/artemis --force; done
   ```
3. Make two fine-grained tokens at https://github.com/settings/personal-access-tokens/new, resource owner `artemisbrowser`:
   - `GITHUB_TOKEN`: repository `artemis-feedback` only. Issues and Contents: read and write.
   - `PUBLIC_TOKEN`: repository `artemis` only. Issues: read and write, nothing else, so a leak can't touch the code.
   - Pick the longest expiration offered and note the date. An expired token turns every report into a 502 (the log shows `github POST /issues 401`). Renew it by making a new one the same way and repeating step 6.
4. `npm i -D wrangler && npx wrangler login`
5. `npx wrangler kv namespace create SIGS`, then paste the printed id into `wrangler.jsonc`.
6. `npx wrangler secret put GITHUB_TOKEN` and `npx wrangler secret put PUBLIC_TOKEN`, pasting each token.
7. `npx wrangler deploy` (artemisbrowser.app has to be a zone on the same Cloudflare account).
8. Smoke test: expect `201` with an `issue` URL, plus a linked private issue.
   ```sh
   curl -i https://feedback.artemisbrowser.app/v1/reports -H 'content-type: application/json' \
     -d '{"kind":"feedback","install":"00000000-0000-4000-8000-000000000000","app":{"version":"0","build":"0"},"os":"curl","model":"curl","arch":"arm64","feedback":{"category":"other","message":"Smoke test","private":true}}'
   ```
