# Artemis website

The site at [artemisbrowser.app](https://artemisbrowser.app). It's plain HTML, CSS and JavaScript, put together by one Node script with nothing to install.

## Running it

You'll need Node.js 24.

```sh
cd website
node build.mjs --serve 8080   # build it and serve it at http://localhost:8080
node build.mjs --check        # build it, then run the checks
```

## Where things are

- `src/partials`: the page, one file per section
- `src/css`, `src/js`: styles and scripts, split the same way
- `src/img`, `src/video`, `assets`: images and clips
- `tools`: the checks and review helpers

## Contributing

It works the same as the app: fork, branch, open a PR against `main`, and sign the CLA on your first one. [CONTRIBUTING.md](../CONTRIBUTING.md) walks through it. Run `node build.mjs --check` before you open the PR, and add a screenshot for anything that changes how the site looks.

## Licence

The website is covered by the same [licence](../LICENSE) as the app: PolyForm Strict 1.0.0, with permission to make changes for a pull request to this repo. You can't host your own copy of the site.
