#!/usr/bin/env bash

export TYPST_FONT_PATHS="${HOME}/.local/share/fonts"

PATHNAME=$1
if [[ -z "$PATHNAME" ]]; then
	echo "Syntax: $0 <path to markdown file>"
	exit 1
fi
REPORTNAME=$(basename -s .md "${PATHNAME}")

pandoc \
	-f gfm+fenced_divs \
	--lua-filter=./scripts/borderless-table.lua \
	--template=./scripts/pandoc-typst.template \
	-V template=./scripts/article.typ \
	--pdf-engine=typst \
	--pdf-engine-opt=--root=/ \
	--resource-path=./md \
	--extract-media=./md \
	./"${REPORTNAME}".md \
	-o "./${REPORTNAME}.pdf"
