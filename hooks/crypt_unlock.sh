#!/bin/sh

PREREQ="dropbear"

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
    ;;
esac

. "${CONFDIR}/initramfs.conf"
. /usr/share/initramfs-tools/hook-functions

# Add keyctl binary to initrd
copy_exec /bin/keyctl

if [ "${DROPBEAR}" != "n" ] && [ -r "/etc/crypttab" ] ; then
    #run unlock on ssh login
    # In some versions of update-initramfs, instead of just a /root dir in the initramfs, it's /root-a12b3 or something like that with a dynamic suffix
    # So the following line figures out what the actual root directory is
    ROOTDIR=`find ${DESTDIR} -maxdepth 1 -type d -name root* -print | head -n 1`
    echo unlock>${ROOTDIR}/.profile
        #write the unlock script
    cat > "${DESTDIR}/bin/unlock" <<EOF
#!/bin/sh

# Read passphrase
read_pass()
{
    # Disable echo.
    stty -echo

    # Set up trap to ensure echo is enabled before exiting if the script
    # is terminated while echo is disabled.
    trap 'stty echo' EXIT SIGINT

    # Read passphrase.
    read "\$@"

    # Enable echo.
    stty echo
    trap - EXIT SIGINT

    # Print a newline because the newline entered by the user after
    # entering the passcode is not echoed. This ensures that the
    # next line of output begins at a new line.
    echo
}

printf "Enter passphrase: "
read_pass password
echo "\$password" >/lib/cryptsetup/passfifo 
EOF

    chmod +x "${DESTDIR}/bin/unlock"

    echo On successful unlock this ssh-session will disconnect. >> ${DESTDIR}/etc/motd
    echo Run \"unlock\" to get passphrase prompt back if you end up in the shell. >> ${DESTDIR}/etc/motd
fi
