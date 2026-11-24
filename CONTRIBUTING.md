# Contributing to Kuri

Kuri's first principle is to be **essential**: few features, done well. That shapes what this repository accepts more than anything else, so please read this before opening a pull request.

## Kuri's scope

Kuri does what it does today, plus one feature still planned: grouping and organizing conversations. Growing beyond that, one feature at a time, isn't what this project is for.

**Welcome:**

- **Bug fixes.** Something that doesn't work as described, crashes, loses data or misbehaves with a provider or MCP server it should support.
- **Performance.** Less memory, less CPU, faster launch, lower energy use. Kuri's footprint is part of its point.
- **Usability of what already exists.** Accessibility, keyboard navigation, clearer wording, closer adherence to macOS conventions, rough edges in an existing flow.
- **Sandbox images.** The sandbox has no network, so its image decides what the model can do. Images specialised for a kind of work (data science, typesetting, a language's toolchain…) extend Kuri without adding a feature to the app. Follow the shape of [`Sandbox/Dockerfile`](Sandbox/Dockerfile): an official base image, packages from the distribution and the language's official registry, built for arm64. Open an issue first, so we can agree on where it lives and how it's published.
- **Documentation.** Corrections and clarifications.

**Usually declined:**

- New features, tools, providers, settings or configuration keys.
- New UI: screens, panels, buttons, menus, themes or redesigns. A UI change should fix or improve something, not just add or restyle it.
- New dependencies.
- Refactors, renames or style changes that don't fix a problem.

A quick test: *does the change make something Kuri already does work better, faster or more clearly?* If yes, it's welcome.

## Ideas are still welcome

This is still open source, and ingenuity is welcome. If you have a feature that you believe would substantially improve Kuri or how well models work in it, or a UI change that would make a workflow better, open an issue and let's talk about it. Some of these will make it in. What Kuri won't do is grow for the sake of growing: a feature has to earn its place, and most ideas, however good, will fit better in a fork.

## Forks are encouraged

If you want Kuri with more in it, fork it. That's not a consolation prize: the license (Apache 2.0) is there for exactly this, and different people wanting different tools is fine. The architecture tries to make it easy: providers are adapters behind one protocol, tools go through one registry, and the engine knows nothing about the UI.

Please give your fork its own name and icon, so people can tell the two apart.

## Before you open a pull request

- **For anything bigger than a small fix, open an issue first.** It saves you time if the change falls outside the scope above.
- **Follow the working agreements in [CLAUDE.md](CLAUDE.md).** They're written for coding agents but apply to everyone: how to build and test, keeping `docs/flows.html` references in step with the code, updating `docs/config.md`, append-only migrations, and when a change needs a decision record.
- **Respect the [decision records](docs/decisions/).** Don't reverse one without a new record that argues for it.
- **Test it.** `cd Packages/KuriKit && swift test` passes, and the app builds.
- **Keep it to one coherent change**, and say what problem it solves and how you checked it. For performance or UI fixes, include before-and-after measurements or screenshots.

Contributions are licensed under Apache 2.0, the same as the rest of Kuri (section 5 of the [license](LICENSE)).

## Reporting bugs

Open an issue with your macOS version and Mac, the provider and model you were using, the steps that lead to the problem, and what you expected instead. Remove API keys and other secrets from anything you paste.
