#!/bin/bash

# This script packs an initrd filesystem unpacked using unpack-initrd.sh to a temporary
# directory.
#
# Author: Stephan Kadauke (skadauke@gmail.com)
#
# Tested: Ubuntu Server 15.04
#
# Notes:
# 1. The script expects to find an initram filesystem in /tmp/initrd
# 2. The script makes a number of assumptions: (1) the initrd is separate from the 
#    kernel. (2) Its path/filename are /boot/initrd.img-<whatever is uname -r> 
#    (as is tradition in Ubuntu and Debian based systems). (3) The initrd is gzipped. 
# 3. All changes made by this script will be overwritten if update-initramfs is invoked.
# 4. The script will replace the initrd used during the current 
#    boot session so if the kernel was updated during the current session 
#    the changes will be reflected only in the old initrd. 


INITRD="/boot/initrd.img-`uname -r`"
INITRD_TMPDIR="/tmp/initrd"

# Am I root?
[ "$(id -u)" == "0" ] || { echo "This script must be run as root."; exit 1; }

# Does the INITRD file exist? (No need to fail if it doesn't as we're creating one)
[ -e $INITRD ] || echo "Warning: cannot find $INITRD. Is this a Debian/Ubuntu based system?"

# Does the INITRD_TMPDIR exist?
[ -d "$INITRD_TMPDIR" ] || { echo "Cannot find $INITRD_TMPDIR. Did you unpack an initrd?"; exit 1; }

read -p "This will replace your initrd and could make your system unbootable. Are you sure? " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]   # not all shells support this but bash does
then 
  # Back up old initrd if it exists
  NOW=$(date +"%m%d%Y_%H%M%S")
  [ -e "$INITRD" ] && mv "$INITRD" "${INITRD}.${NOW}"
  
  # Is the /tmp/initrd directory present?
  [ -d "$INITRD_TMPDIR" ] || { echo "/tmp/initrd directory does not exist."; exit 1; }

  # Pack initrd
  cd "$INITRD_TMPDIR"
  find . -print0 | cpio --null -ov --format=newc | gzip -9 > $INITRD
fi
