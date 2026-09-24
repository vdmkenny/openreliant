# Notes for coding agents

[CONTRIBUTING.md](CONTRIBUTING.md) holds the project's conventions: follow it in full. These notes
add how the maintainer works with an agent.

- **Starting an issue.** Begin with `gh issue view N --comments`, and read the comments on related
  closed issues too.
- **Trying a change.** When the maintainer tries a change in the game, build and launch it right
  away: `make play`, or `zig build -Doptimize=ReleaseSafe` and then
  `zig-out/bin/openreliant <game directory>`. Once they are happy with it, run the checks and
  commit.
- **Pull requests.** Push the feature branch and open the pull request when the change is ready.
  The maintainer merges it. See one pull request merged before starting the next feature.
- **Attribution.** Commits and pull requests carry the maintainer's git identity alone. End commit
  messages and pull request bodies with their content, leaving out trailers such as
  `Co-Authored-By` and "Generated with" footers.
- **Gaps.** File an issue for each gap you leave, under its milestone, and name the issues in your
  reply.
- **Replies.** Write replies in the same plain style and punctuation as the docs.
- **Disk space.** `.zig-cache` grows by gigabytes; `make zig-clean` frees it when the disk fills.
