# 0005. One shell; no file tools, no artifacts

Status: accepted

## Context
Agents commonly get `read_file`, `write_file`, `edit_file`, `list_files`… plus a separate concept of generated documents ("artifacts") to store and preview.

## Decision
The model touches files only through the `shell` tool, which runs in the conversation's sandbox on the folders mounted at `/work`. There are no file tools and no artifacts: a file the model creates is a file, in an attached folder or the conversation's scratch folder.

## Consequences
- One tool, one path namespace, one place to sandbox and to audit.
- Without the sandbox set up, the model can't touch files at all.
- File-oriented UI (diffs, previews) will have to work from the folders themselves, not from a special store.
