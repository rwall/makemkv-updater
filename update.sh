#!/bin/bash
cleanup() {
	cd /tmp
	if [ -n "$TMPDIR" ]; then
		rm -rf $TMPDIR
	fi
}

cleanup_and_bail() {
	cleanup
	if [ "$2" ]; then
		echo "ERROR: $2" 1>&2
	fi
	exit $1
}

MKVCON=`which makemkvcon`
MKVVER=''
BINVER=''
OSSVER=''
if [ ! -f "$MKVCON" ]; then
	echo "MakeMKV not found. Overriding version number to force upgrade"
	MKVVER='0.0.0'
else
	MKVVER=$($MKVCON version 2>/dev/null | head -n 1 | cut -d " " -f 2 | sed -e 's/^v//' )
	if [ ! "$MKVVER" ]; then
		MKVVER='0.0.0'
		echo "MakeMKV but no version detected. Likely a half-broken install. Overriding the version number to force upgrade."
	fi
	echo "Using MakeMKV version: $MKVVER" 1>&2
fi

URL='http://www.makemkv.com/forum2/viewtopic.php?f=3&t=224'
declare -A URLASSOC
IFS=$'\n'
FILES=($(curl -v $URL 2>/dev/null | grep -o -P -e 'http:\/\/www.makemkv.com\/download\/makemkv-(bin|oss)-\d+\.\d+\.\d+\.tar\.gz' 2>/dev/null | sort -u 2>/dev/null))
unset IFS

for ((i = 0; i <= 1; i++ )); do
	if   [[ ${FILES[$i]} == *"bin"* ]]; then
		URLASSOC[bin]=${FILES[$i]}
		BINVER=$(echo "${FILES[$i]}" | grep -oPe '\d+\.\d+\.\d+')
	elif [[ ${FILES[$i]} == *"oss"* ]]; then
		URLASSOC[oss]=${FILES[$i]}
		OSSVER=$(echo "${FILES[$i]}" | grep -oPe '\d+\.\d+\.\d+')
	else
		echo "ERROR: got strange return on url search (${FILES[$i]})" 1>&2
		exit 127
	fi
done

# we have URLs,which gives us versions. let's check version numbers
IFS=$'.'
INSTALLED_VERSION=($MKVVER)
BINVERASSOC=($BINVER)
OSSVERASSOC=($OSSVER)
unset IFS

# pointless to continue if bin/oss versions don't match
if [ ${BINVERASSOC[0]} -ne ${OSSVERASSOC[0]} ] || 
   [ ${BINVERASSOC[1]} -ne ${OSSVERASSOC[1]} ] || 
   [ ${BINVERASSOC[2]} -ne ${OSSVERASSOC[2]} ]; then
	echo "bin/oss version mismatch"
	exit 127
elif [ "$MKVVER" = "$BINVER" ]; then
	echo "Installed version is already the newest available"
	cleanup_and_bail 0
fi

for ((i = 0; i <= 2; i++)); do
	if [ "${BINVERASSOC[$i]}" -lt "${INSTALLED_VERSION[$i]}" ]; then
		echo "Installed version is newer than bin/oss downloads" 1>&2
		echo "(how does that even happen??)" 1>&2
		exit 127
	fi
done

# version check shouldn't require root. but some of this stuff does.
# let's check root and re-run on via sudo if necessary
# yes, that means the version check will be done again but that's ok
if [ "$UID" -ne "0" ]; then
	echo "You are not root. This will be a problem."
	SUEXEC=
	SUDO=$(which sudo)
	KDESUDO=$(which kdesudo)
	GTKSUDO=$(which gksudo)
	if [ "$XDG_CURRENT_DESKTOP" == "KDE" ] && [ "$KDESUDO" ]; then
		SUEXEC=$KDESUDO
	elif [ "$XDG_CURRENT_DESKTOP" == "GNOME" ] && [ "$GTKSUDO" ]; then
		SUEXEC=$GTKSUDO
	elif [ "$SUDO" ]; then
		SUEXEC=$SUDO
	else
		echo "FAlling back to useing $SUDO"
		cleanup_and_bail 127 "Failure to find a suitable sudo"
	fi 
	echo "re-running with sudo"
	$SUEXEC $0
	cleanup_and_bail 0
else
	echo "You're already root. good."
fi

# If we are here, the version checks have passed
echo "Version checks passed, continuing the upgrade"
IFS=$'/'
TMP=(${URLASSOC[bin]})
BINFILE=${TMP[-1]}
TMP=(${URLASSOC[oss]})
OSSFILE=${TMP[-1]}
unset IFS
BINDIR=$(basename $BINFILE .tar.gz)
OSSDIR=$(basename $OSSFILE .tar.gz)

TMPDIR=$(mktemp -d)
cd $TMPDIR

GETCMD=
CURL=$(which curl)
WGET=$(which wget)
if [ -f $CURL ]; then
	GETCMD="$CURL -O "
elif [ -f $WGET ]; then
	GETCMD="$WGET "
else
	cleanup_and_bail 127 'Failed to find curl or wget. Make sure one is installed and in your PATH'
fi


for type in bin oss; do
	echo "Downloading $type file"
	$GETCMD ${URLASSOC[$type]} 2>/dev/null
	if [ "$?" -ne "0" ]; then
		cleanup_and_bail 126 "curl/wget returned failure status: $?"
	fi
done

# make sure the files are actually there as we expect
if [ ! -f "$TMPDIR/$BINFILE" ] || [ ! -f "$TMPDIR/$OSSFILE" ]; then
	cleanup_and_bail 125 "$BINFILE or $OSSFILE doesn't exist in tmpdir $TMPDIR"
fi

echo "Extracting $BINFILE"
tar zxf $BINFILE >/dev/null 2>&1
if [ "$?" -ne "0" ]; then
	cleanup_and_bail 124 "Failure extracting $BINFILE"
fi
echo "Extracting $OSSFILE"
tar zxf $OSSFILE >/dev/null 2>&1
if [ "$?" -ne "0" ]; then
	cleanup_and_bail 124 "Failure extracting $OSSFILE"
fi

# prep for build
apt-get install build-essential pkg-config libc6-dev libssl-dev libexpat1-dev libavcodec-dev libgl1-mesa-dev libqt4-dev >/dev/null 2>&1 || cleanup_and_bail 123 "Failure installing necessary packages"

# build oss part
echo "Building OSS"
cd $OSSDIR || cleanup_and_bail 122 "Failure to CD to $OSSDIR"
(./configure && make) >/dev/null 2>&1		|| cleanup_and_bail 121 "OSS Build failure"
cd $TMPDIR

# build bin part
echo "Building BIN"
cd $BINDIR || cleanup_and_bail 122 "Failure to CD to $BINDIR"
( mkdir tmp && touch tmp/eula_accepted )	|| cleanup_and_bail 121 "Unable to cheat eula for BIN package"
( make ) >/dev/null 2>&1			|| cleanup_and_bail 121 "BIN Build failure"
cd $TMPDIR

# if we got this far, makes all ran ok. do the installs
echo "Installing OSS"
( cd $OSSDIR && make install ) >/dev/null 2>&1	|| cleanup_and_bail 120 "Failure to install OSS"
cd $TMPDIR
echo "Installing BIN"
( cd $BINDIR && make install ) >/dev/null 2>&1	|| cleanup_and_bail 120 "Failure to install BIN"
cd $TMPDIR

echo "Done. Thank You!"
cleanup_and_bail 0

