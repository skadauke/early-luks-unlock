#!/bin/sh

# This script unlocks a LUKS-encrypted volume using a passphrase entered in the console
# or via SSH or using a keyfile on removable storage. It supports caching of passphrases
# as well as encrypted removable storage.
#
# It is meant to be used as a keyscript in /etc/crypttab or its initramfs-tools equivalent
# /conf/conf.d/cryptroot.
#
# Author: Stephan Kadauke (skadauke@gmail.com)
#
# The script is based on (and borrows heavily from) crypto-root-fs.sh originally written 
# by wejn, and improved by kix, TJ, Hendrik van Antwerpen, Jan-Pascal van Best, Renaud Metrich, 
# dgb, Travis Burtrum, and Martin van Beurden.
#
# Tested: Ubuntu Server 15.04
#
# Notes:
# 1. Usplash support was removed as Usplash has been deprecated since Ubuntu 10
# 2. Support for USB/MMC devices has not been tested extensively. This code has been taken over
#    with some modifications from Martin van Beurden's version of crypto-usb-key.sh. Bug fixes
#    are welcome.
# 3. Encrypted key drives are supported only if the partition containing the key file is 
#    LUKS encrypted (e.g., /dev/sdc1), not if the entire drive is encrypted (e.g., /dev/sdc)

# Counterintuitive shell logic
TRUE=0			
FALSE=1			

###############################################################################
# Configuration
###############################################################################

# set DEBUG=$TRUE to display dbg messages, DEBUG=$FALSE to be quiet
DEBUG=$TRUE		

# How long to cache passwords (seconds)
KEYCTL_TIMEOUT=60

# Time to sleep for removable devices to become ready before asking passphrase
MAX_SECONDS_SLEEP=2


###############################################################################
# Initialization
###############################################################################

# CRYPTTAB_KEY is exported by the cryptroot script. This variable contains the path to 
# the keyfile (stored in KEYFILE variable), or alternatively, a descriptor to identify a 
# specific passphrase cached by keyctl (stored in KEYCTL_ID variable). It corresponds
# to the third field of an entry of /etc/crypttab
KEYFILE="$CRYPTTAB_KEY" 
KEYCTL_ID="$CRYPTTAB_KEY"

# CRYPTTAB_NAME is exported by the cryptroot script. This variable contains the name of
# the mapped device that will be created in /dev/mapper. It corresponds to the first field
# of an entry of /etc/crypttab
TARGET_VOLUME="$CRYPTTAB_NAME"

# Mount point for USB/MMC key
KEYDRIVE_MOUNTPOINT=/keydrive

# Variable to hold a list of potential removable storage drives
DRIVES=""

# Is plymouth available?
if [ -x /bin/plymouth ] && plymouth --ping; then
    PLYMOUTH=$TRUE
else
	PLYMOUTH=$FALSE
fi

# Is stty available?
if [ -x /bin/stty ]; then
    STTY=$TRUE
    STTYCMD=/bin/stty
elif [ `(busybox stty >/dev/null 2>&1; echo $?)` -eq $TRUE ]; then
    STTY=$TRUE
    STTYCMD="busybox stty"
else
	STTY=$FALSE
	STTYCMD=false
fi


###############################################################################
# Helper functions
###############################################################################

# Print message to plymouth or stderr
# usage: msg "message" [switch]
# switch : switch used for echo to stderr
# using the switch -n will allow echo to write multiple messages
# to the same line
msg ()
{
    if [ $# -gt 0 ]; then
        # handle multi-line messages
        echo $1 | while read LINE; do
            if [ $PLYMOUTH -eq $TRUE ]; then
                # use plymouth
                plymouth message --text="$LINE"
            else
                # use stderr for all messages
                echo $2 "$1" >&2
            fi
        done
    fi
}

# same as msg () but silent if DEBUG=$FALSE
dbg ()
{
    if [ $DEBUG -eq $TRUE ]; then
        msg "$@"
    fi
}


###############################################################################
# Routines
###############################################################################

# Add a key to kernel keyctl
# usage: keyctl_addkey "passphrase" "keyctl_id"
keyctl_addkey ()
{
    [ $# -eq 2 ] || { msg "Error: keyctl_addkey needs two arguments: PASS and KEYCTL_ID."; return $FALSE; }

    local PASS KEYCTL_ID
	PASS=$1
    KEYCTL_ID=$2

	# Workaround for keyctl issue: if we cannot attach a key to the @u ring, use @s instead
	keyctl timeout $(keyctl add user test test @u) 60 >/dev/null 2>&1
	if [ $? -eq $TRUE ]
		KEYCTL_RING="@u"
	else
		dbg "keyctl: cannot change timeout on keyring @u, using @s instead"
		KEYCTL_RING="@s"
	fi
	keyctl unlink `keyctl request user test >/dev/null 2>&1` >/dev/null 2>&1

	# Add passphrase to keyring
    KEYRING_ID=$(echo -n $PASS | keyctl padd user $KEYCTL_ID $KEYCTL_RING)

    [ -z KEYRING_ID ] && { msg "Error adding passphrase to kernel keyring"; return $FALSE; }
    if ! keyctl timeout $KEYRING_ID $KEYCTL_TIMEOUT; then
        msg "Error setting timeout of key ${KEYRING_ID}, removing"
        keyctl unlink $KEYRING_ID $KEYCTL_RING
    fi

    echo -n $KEYRING_ID
}

# Read password from console or with plymouth
# usage: readpass "prompt"
# TODO: Test askpass code
readpass ()
{
    if [ $# -gt 0 ]; then
        if [ $PLYMOUTH -eq $TRUE ]; then
			local PIPE PLPID
			PIPE=/lib/cryptsetup/passfifo
			mkfifo -m 0600 $PIPE
			plymouth ask-for-password --prompt "$1"  >$PIPE &
			PLPID=$!
			read PASS <$PIPE	# SSH unlock session will write into the same pipe
			kill $PLPID >/dev/null 2>&1
			rm -f $PIPE
        elif [ -f /lib/cryptsetup/askpass ]; then
            PASS=$(/lib/cryptsetup/askpass "$1")
        else
            msg "WARNING No SSH unlock support available"
            [ $STTY -ne $TRUE ] && msg "WARNING stty not found, password will be visible"
            echo -n "$1" >&2
            $STTYCMD -echo
            read -r PASS </dev/console >/dev/null
            [ $STTY -eq $TRUE ] && echo >&2
            $STTYCMD echo
        fi
    fi
    echo -n "$PASS"
}

# Enumerate all device nodes corresponding to USB and MMC drives 
# Returns $TRUE if any devices found and $FALSE otherwise
enum_usb_mmc_drives ()
{
    # Is the USB driver loaded?
    cat /proc/modules | busybox grep usb_storage >/dev/null 2>&1
    USBLOAD=0$?				# TODO: Why not USBLOAD=$? See also below
    if [ $USBLOAD -gt 0 ]; then
        dbg "Loading driver 'usb_storage'"
        modprobe usb_storage >/dev/null 2>&1
    fi

    # Is the MMC (SDcard) driver loaded?
    cat /proc/modules | busybox grep mmc >/dev/null 2>&1
    MMCLOAD=0$?
    if [ $MMCLOAD -gt 0 ]; then
        dbg "Loading drivers 'mmc_block' and 'sdhci'"
        modprobe mmc_block >/dev/null 2>&1
        modprobe sdhci >/dev/null 2>&1
    fi
	
    USB_LOADED=$FALSE
    mkdir -p $KEYDRIVE_MOUNTPOINT

	for SECONDS_SLEPT in $(seq 1 1 $MAX_SECONDS_SLEEP); do

		# Examine potential USB or MMC devices
		for BLOCKDRV in $(ls -d /sys/block/sd* /sys/block/mmc* 2> /dev/null); do
			# device name, e.g. sdg
			local DRIVE
			DRIVE=`busybox basename $BLOCKDRV`
			dbg "Examining $DRIVE"
		
	        # is it a USB or MMC device?
	        (cd ${BLOCKDRV}/device && busybox pwd -P) | busybox grep 'usb\|mmc' >/dev/null 2>&1
	        USB=0$?
	        dbg ", USB/MMC=$USB" -n
	        if [ $USB -ne $TRUE -o ! -f $BLOCKDRV/dev ]; then
	            dbg ", device $DRIVE ignored"
			else
				USB_LOADED=$TRUE
				DRIVES="$DRIVES $DRIVE"
	        fi
		done
	
	    # If USB is loaded we must give up, otherwise sleep for a second
	    if [ $USB_LOADED -eq $TRUE ]; then
	       dbg "USB/MMC Device found in less than ${SECONDS_SLEPT}s"
		   return $TRUE
	    elif [ $SECONDS_SLEPT -ne $MAX_SECONDS_SLEEP ]; then
	       dbg "USB/MMC Device not found yet, sleeping for 1s and trying again"
	       sleep 1
	    else           
	       dbg "USB/MMC Device not found, giving up after ${MAX_SECONDS_SLEEP}s... (increase MAX_SECONDS_SLEEP?)"
		   return $FALSE
	    fi
	done
}

# Check whether keyfile exists and, if so, pipe it the STDOUT and exit
# the script. Otherwise, return $FALSE
check_for_keyfile ()
{
	if [ -f $KEYDRIVE_MOUNTPOINT/$KEYFILE ]; then
	    dbg "Found $KEYFILE"
	    cat $KEYDRIVE_MOUNTPOINT/$KEYFILE
		msg "Unlocking $TARGET_VOLUME using keyfile ${KEYFILE}."
		exit $TRUE
	else
		return $FALSE
	fi
}

# Check if the key device itself is encrypted, and if so, prompt for a passphrase,
# unlock it, and redirect DEV to the mapped device
try_decrypt_key_device ()
{
    # Check if key device is encrypted
    /sbin/cryptsetup isLuks /dev/${DEV} >/dev/null 2>&1
    ENCRYPTED=0$?
    DECRYPTED=$FALSE
    # Open crypted partition and prepare for mount
    if [ $ENCRYPTED -eq $TRUE ]; then
        dbg ", encrypted device" -n
        # Use blkid to determine label
        LABEL=$(/sbin/blkid -s LABEL -o value /dev/${DEV})
        dbg ", label $LABEL" -n
        TRIES=3
        DECRYPTED=$FALSE
        while [ $TRIES -gt 0 -a $DECRYPTED -ne $TRUE ]; do
            TRIES=$(($TRIES-1))
            PASS=$(readpass "Enter LUKS password for key device ${DEV} (${LABEL}) (or empty to skip): ")
            if [ -z "$PASS" ]; then
                dbg ", device skipped" -n
                break
            fi
            echo $PASS | /sbin/cryptsetup luksOpen /dev/${DEV} bootkey >/dev/null 2>&1
            DECRYPTED=0$?
        done
        # If open failed, skip this device
        if [ $DECRYPTED -ne $TRUE ]; then
            dbg "decrypting device failed" -n
            break
        fi
        # Decrypted device to use
        DEV=mapper/bootkey
    fi
}

# Attempt to mount the device. Return $TRUE if successful, $FALSE otherwise.
try_mount_device ()
{
	dbg ", device $DEV" -n
    # Use blkid to determine label
    LABEL=$(/sbin/blkid -s LABEL -o value /dev/${DEV})
    dbg ", label $LABEL" -n
    # Use blkid to determine fstype
    FSTYPE=$(/sbin/blkid -s TYPE -o value /dev/${DEV})
    dbg ", fstype $FSTYPE" -n
    # Is the file-system driver loaded?
    cat /proc/modules | busybox grep $FSTYPE >/dev/null 2>&1
    FSLOAD=0$?
    if [ $FSLOAD -gt 0 ]; then
        dbg ", loading driver for $FSTYPE" -n
        # load the correct file-system driver
        modprobe $FSTYPE >/dev/null 2>&1
    fi
    dbg ", mounting /dev/$DEV on $KEYDRIVE_MOUNTPOINT" -n
    mount /dev/${DEV} $KEYDRIVE_MOUNTPOINT -t $FSTYPE -o ro >/dev/null 2>&1
	if [ $? -eq $TRUE ]; then
		dbg ", (`mount | busybox grep $DEV`)" -n
		return $TRUE
	else
		dbg ", mount FAILED."
		return $FALSE
	fi
}

# Unmount key device and close encrypted key device
clean_up ()
{
    umount $KEYDRIVE_MOUNTPOINT >/dev/null 2>&1
    
    if [ $ENCRYPTED -eq $TRUE -a $DECRYPTED -eq $TRUE ]; then
        dbg ", closing encrypted device" -n
        /sbin/cryptsetup luksClose bootkey >/dev/null 2>&1
    fi
}


###############################################################################
# Begin real processing
###############################################################################

dbg "Executing luks-unlock.sh to unlock $TARGET_VOLUME ..."

#
# Stage 1: Check for a cached passphrase 
#

dbg "Checking if a cached passphrase is available"

# Check if there is a cached keyphrase for the present keyctl id
# If so, pipe the cached key to STDOUT and exit the script
KEYRING_ID=$(keyctl search $KEYCTL_RING user "$KEYCTL_ID" 2>/dev/null)
if [ -n "$KEYRING_ID" ]; then
    # Cached key found!
    dbg "The KEYRING_ID for KEYCTL_ID $KEYCTL_ID is '${KEYRING_ID}'."
    msg "Unlocking $TARGET_VOLUME using cached passphrase."
    keyctl pipe $KEYRING_ID
    exit 0
else
    dbg "No key ring found for KEYCTL_ID ${KEYCTL_ID}."
fi

#
# Stage 2: Check for a keyfile on removable storage
#

dbg "Checking if a keyfile is available on removable storage"

# If the keydrive is already mounted from a previous invocation of the
# script, check if the keyfile for the current drive is there.
# Script exits if keyfile is found. 
check_for_keyfile

# Find all device nodes corresponding to USB and MMC drives
enum_usb_mmc_drives
if [ $? -eq $TRUE ]
	dbg "Found the following USB/MMC drives: $DRIVES"

	# Try to mount key drive partitions. Check for keyfile and exit
	# script if successful.
	for DRIVE in $DRIVES; do
		for SFS in $(ls -d /sys/block/$DRIVE/sd* /sys/block/$DRIVE/mmc* 2> /dev/null); do
			dbg ", *possible key device*" -n
			DEV=`busybox basename $SFS`

			# Check if key device itself is encrypted. In this case, decrypt it and change
			# DEV to the mapped device
			try_decrypt_key_device

			# Try to mount device, otherwise skip to the next one
			try_mount_device || continue
		
			# Check for keyfile
			dbg ", checking for $KEYDRIVE_MOUNTPOINT/$KEYFILE"
			check_for_keyfile

			# we only get here if the keyfile was not found
			dbg "Keyfile not found, umount $DEV from $KEYDRIVE_MOUNTPOINT" -n
			clean_up
		
		    dbg ", done"
		    dbg ""
		done
	done
else
	dbg "Found no USB or MMC devices."
fi

#
# Stage 3: Ask for a passphrase
#

PASS=$(readpass "$(printf "Enter passphrase: ")")

# Add passphrase to keyctl
dbg "Call keyctl_addkey PASS $PASS to KEYCTL_ID ${KEYCTL_ID}."
KEYRING_ID=$(keyctl_addkey "$PASS" "$KEYCTL_ID")
if [ -z $KEYRING_ID ]; then
	dbg "keyctl_addkey failed."
else
    dbg "keyctl_addkey successful, KEYRING_ID ${KEYRING_ID}."
fi

# Wait a bit to be able to see messages
[ $DEBUG -eq $TRUE ] && sleep 15		

echo -n $PASS