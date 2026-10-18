# Changelog

What changed in Ascella, newest first. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and each entry is
tagged so that a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a hole closed, or judged not to be one |
| [Verified] | checked against the real thing, no code change |

A version is released when its number is in `mix.exs` **and** it has a
section here: the release's page on GitHub is that section, word for word.
See [docs/releasing.md](docs/releasing.md).

## [Unreleased]

## [0.1.0] - 2026-10-18

- [Feature] **One page for the hall's programs.** A tile each for OpenPairings, Alnasl, Arkab, Polis and Nunki, with its mark, what is installed, what is out and whether it runs; Install, Update, Start, Stop and Open per program, and Update all, which does them one at a time because a hall has one network and no patience. English and Dutch.
- [Feature] **The catalogue is data.** `priv/catalogue.json` says which programs there are, where on GitHub they live and what their downloads are called. A program that ships the way Alnasl does is one entry, so adding Polis or Nunki later is a paragraph of JSON, not a release of anything.
- [Feature] Windows: each program's own Velopack does the installing and updating, macOS gets its `.app` swapped in one rename with the previous one kept for a rollback, and Linux runs the programs' own install and update scripts and their own systemd units. Ascella provides the button and the nagging.
- [Feature] Ascella updates itself the way Alnasl does. The cobbler's children get shoes.
- [Security] **Every download is checked against the `SHA256SUMS` of its release**, and checked again just before it runs. No list, not on the list, or the wrong sum: refused and deleted. Only GitHub, only HTTPS, and a redirect anywhere else is a failed download rather than an adventure.
- [Security] **No data directory is ever written, moved or deleted.** Every file operation goes through a guard that knows every program's data folders, a Windows install folder holding a database stops the update cold, and a catalogue that would put a data folder where an uninstaller can reach it does not load. A program that will not stop is left running, unchanged; nothing is ever killed. Earlier experience suggests this is not paranoia.
- [Security] The page answers only on 127.0.0.1. A page that installs programs for anyone on the hall's wifi would be a remote installer with a nice font.
