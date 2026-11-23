# Kuri's sandbox image: what the model's `shell` tool runs in.
#
# The sandbox has no network, so whatever is here is all the model can use:
# Python's standard library, plus a few tools and libraries for the files
# people hand it (PDFs, Word and Excel documents, images, data, repositories).
# Keep it small and essential.
#
# Published to ghcr.io/haruno19/kuri-sandbox by .github/workflows/sandbox-image.yml,
# tagged with the number in VERSION. Bump VERSION with every change here, and
# SandboxSettings.kuriImage in KuriSandbox to match.

FROM docker.io/library/python:3-slim

LABEL org.opencontainers.image.source="https://github.com/Haruno19/kuri"
LABEL org.opencontainers.image.description="The Linux sandbox Kuri's shell tool runs in: Python with tools for documents and data."

# Command-line tools, from Debian:
#   poppler-utils   pdftotext, pdftoppm, pdfinfo: text and pages out of PDFs
#   pandoc          converting between Markdown, Word, HTML and more
#   imagemagick     inspecting, converting and resizing images
#   ripgrep, jq     searching text, reading JSON
#   git, sqlite3    repositories and databases
RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        poppler-utils pandoc imagemagick ripgrep jq git sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Python libraries, from PyPI:
#   pypdf, pdfplumber   reading PDFs (text, tables, metadata)
#   pandas, openpyxl    tables, CSV and Excel
#   python-docx         Word documents
#   pillow, matplotlib  images and charts
RUN pip install --no-cache-dir --root-user-action=ignore \
        pypdf pdfplumber pandas openpyxl python-docx pillow matplotlib

# No display: charts are written to files.
ENV MPLBACKEND=Agg

WORKDIR /work
