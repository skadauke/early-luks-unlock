#!/bin/bash

# This script unpacks an initrd into a temporary folder so it can be modified for 
# testing. The counterpart to this script is pack-initrd.sh, which backs up the
# original initrd and replaces it with one containing modifications.
#
# Author: Stephan Kadauke (skadauke@gmail.com)
#
# Tested: Ubuntu Server 15.04
# 
# Notes:
# 1. The script extracts the initrd filesystem to /tmp/initrd (INITRD_TMPDIR)
# 2. The script makes a number of assumptions: (1) the initrd is separate from the 
#    kernel. (2) Its path/filename are /boot/initrd.img-<whatever is uname -r> 
#    (as is tradition in Ubuntu and Debian based systems). (3) The initrd is gzipped. 
# 3. The script will work with the initrd used during the current boot session.
#
# TODO: Combine the pack and unpack scripts (DRY!)


INITRD="/boot/initrd.img-`uname -r`"
INITRD_TMPDIR="/tmp/initrd"

# Am I root?
[ "$(id -u)" == "0" ] || { echo "This script must be run as root."; exit 1; }

# Does the INITRD file exist?
[ -e $INITRD ] || { echo "Cannot find $INITRD. Is this a Debian/Ubuntu based system?"; exit 1; }

# Remove old temporary initrd filesystem?
if [ -d "$INITRD_TMPDIR" ] 
then
  read -p "$INITRD_TMPDIR exists. Overwrite? " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]   # not all shells support this but bash does
  then
    rm -r $INITRD_TMPDIR
  else
    exit 1
  fi
fi

# Unpack INITRD to INITRD_TMPDIR
mkdir -p "$INITRD_TMPDIR"
cd "$INITRD_TMPDIR"
gzip -dc $INITRD | cpio -id

