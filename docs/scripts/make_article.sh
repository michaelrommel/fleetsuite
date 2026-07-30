#!/usr/bin/env bash

ARTICLE=$1

if [[ -z "$ARTICLE" ]]; then
	echo "Usage: $0 <articlename>"
	exit 1
fi

pandoc -f gfm+fenced_divs \
	--lua-filter=./scripts/borderless-table.lua \
	--lua-filter=./scripts/diagram.lua \
	--template=./scripts/pandoc-typst.template \
	--variable template:./scripts/article.typ \
	--pdf-engine=typst \
	--pdf-engine-opt=--root=/ \
	--resource-path=./md \
	--extract-media=./md \
	./md/${ARTICLE}.md \
	-o ./pdf/${ARTICLE}.pdf
