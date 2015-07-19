#!/bin/sh

OLDUID=$1
NEWUID=$2

if [ $# -ne 2           ]; then
	echo "Type 'sudo $0 {OLDUSER|OLDUID} {NEWUSER|NEWUID}'"
	exit 1
fi
if [ `whoami` != "root" ]; then
	echo "Type 'sudo $0 {OLDUSER|OLDUID} {NEWUSER|NEWUID}'"
	exit 2
fi

find / -name Backups.backupdb -prune -or \( -type f -or -type d \) -user $OLDUID -print  | while read ITEM
do
	isLOCK=`ls -lO "$ITEM" | awk '$5 == "uchg" {print $0 }' | wc -l`
	if [ $isLOCK -eq 1 ]; then chflags nouchg "$ITEM" ; fi
	chown $NEWUID "$ITEM"
	if [ $isLOCK -eq 1 ]; then chflags uchg   "$ITEM" ; fi
done
