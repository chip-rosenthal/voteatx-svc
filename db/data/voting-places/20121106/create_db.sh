#!/bin/sh

USAGE="usage: $0 database"

if [ $# -ne 1 ] ; then
	echo "$USAGE" >&2
	exit 1
fi
DATABASE="$1"

if [ -f "$DATABASE" ] ; then
	echo "$0: will not overwrite existing file \"$DATABASE\"" >&2
	exit 1
fi

set -e
../../voting-districts/2012/load_vtd2012a.sh $DATABASE voting_districts
ruby generate.rb $DATABASE

