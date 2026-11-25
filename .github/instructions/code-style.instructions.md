---
applyTo: "**/*.rb"
---

# Code style

- **No code comments.** If code needs a comment to be understood, the code is wrong: rename, extract a method or a class until it reads on its own. A comment is the rare exception, for a reason the code cannot show, such as a workaround for a bug in a gem, with a link to it.
- **Context goes elsewhere.** Why a change was made, where data came from and what was considered belong in the commit message, the pull request or the issue, not in the source.
- **Specs never test comments** or other prose in source files.
- **Keyword arguments** for anything a reader would otherwise have to look up (`ReleaseService.find_by(sha1:)`).
