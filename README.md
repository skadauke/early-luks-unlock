# early-luks-unlock

This is a set of scripts to support whole-server encryption in systems with one or more LUKS-encrypted disks. 

The luks-unlock.sh script is based on (and borrows heavily from) crypto-usb-key.sh originally written by wejn, and improved by kix, TJ, Hendrik van Antwerpen, Jan-Pascal van Best, Renaud Metrich, dgb, Travis Burtrum, and Martin van Beurden. The supplementary scripts were lifted more or less verbatim from Martin van Beurden's github repo. 

The luks-unlock.sh script has been tested on Ubuntu Server 15.04. It should work on newer Debian-based systems.

## Features

- Unlock a LUKS whole-server encryption setup with multiple drives during initramfs stage _(at this point the script only supports unlocking an encrypted root drive)_
- Multiple modes of unlocking supported:
  - Password entered via local console
  - Password entered after remote login via SSH
  - Keyfile on removable (USB or SD flash) storage, which itself may be encrypted using LUKS
- Passphrase caching with keyctl


## Planned features

- Support for unlocking multiple drives (not just root)
- Get notified by e-mail that the server is waiting to be unlocked
- Install script to generate hook scripts compatible with initramfs-tools


## How to use this script to unlock a LUKS-encrypted root partition

Note: These instructions assume that you know what LUKS is, and that you have clean install of an Ubuntu Server system with a root partition encrypted using LUKS with a passphrase (which is what you get when you choose `Guided - use entire disk and set up encrypted LVM` during the `Partition disks` dialogue of the Ubuntu Server install). In addition, it is assumed that SSH access is enabled on the server using a default user account. Some of these steps, if performed incorrectly, may make your system unbootable, so follow them at your own risk.

Download the scripts:

    $ cd /usr/local/sbin
    $ sudo wget https://raw.githubusercontent.com/skadauke/early-luks-unlock/master/luks-unlock.sh
    $ sudo chmod +x luks-unlock.sh
    $ cd /etc/initramfs-tools/hooks
    $ sudo wget https://raw.githubusercontent.com/skadauke/early-luks-unlock/master/hooks/crypt_unlock.sh
    $ sudo chmod +x crypt_unlock.sh
    $ cd /etc/initramfs-tools/scripts/local-bottom
    $ sudo wget https://raw.githubusercontent.com/skadauke/early-luks-unlock/master/scripts/local-bottom/kill_dropbear_connections
    $ sudo chmod +x kill_dropbear_connections
    $ sudo wget https://raw.githubusercontent.com/skadauke/early-luks-unlock/master/scripts/local-bottom/reset_network
    $ sudo chmod +x reset_network
    
Install `keyutils` to allow passphrase caching.
    
    $ sudo apt-get install keyutils
    
Depending on whether you'd like to unlock your system using a passphrase (entered via SSH or console) or using a key drive on removable storage (USB stick or SD flash card) follow either [A) Using a passphrase](#a-using-a-passphrase) or [B) Using a key file on removable storage](#b-using-a-key-file-on-removable-storage).

### A) Using a passphrase

The following steps are needed to allow SSH access:

    $ sudo apt-get install dropbear

By default, the dropbear SSH server requires RSA key passwordless authentication. During dropbear installation, a private/public SSH RSA key combination is generated. To be able to connect from a client to the server, the private SSH RSA key needs to be copied to the client.

Type the following commands on the **server**. Note: replace `user` with your default user account name:

    $ sudo cp /etc/initramfs-tools/root/.ssh/id_rsa ~/dropbear_id_rsa
    $ sudo chown user:user ~/dropbear_id_rsa

Type the following command on the **client** (Mac OS X Terminal or Linux) to copy the private key to the client. Note: replace `user` with your default user account name on the server, `server` with the server name, and `serverIP` with the server's IP address.

    $ scp user@serverIP:~/dropbear_id_rsa ~/.ssh/server_dropbear_id_rsa

Add the following to the end of `~/.ssh/config`:

    Match originalhost serverIP user root
        HostName serverIP
        User root
        UserKnownHostsFile ~/.ssh/known_hosts.initramfs
        IdentityFile ~/.ssh/server_dropbear_id_rsa

If you'd like to enable password login to the dropbear SSH server, you need to add a password to the `/etc/passwd` file on the initrd. You don't want this to be the same as the system password! Note: replace `password` with the password you want to use to log into the dropbear SSH server.

    $ openssl passwd -1 -salt xyz 'password'
    
Then edit `/usr/share/initramfs-tools/hooks/dropbear`. Replace

    echo "root:x:0:0:root:/root:/bin/sh" > "${DESTDIR}/etc/passwd"

with

    echo ‘root:<encryptedpassword>:0:0:root:/root:/bin/sh' > "${DESTDIR}/etc/passwd"

Note: the double quotes around the `root:...` string need to be changed to single quotes! Also, replace `encryptedpassword` with the output of the `openssl` command above.

Now edit `/etc/crypttab` to point to the `luks-unlock.sh` key script. To do so, add the option `keyscript=/usr/local/sbin/luks-unlock.sh` to the root. The entry should look similar to this:

    sda5_crypt UUID=44395a32-d586-4f55-9b16-163ab0f415cb none luks,keyscript=/usr/local/sbin/luks-unlock.sh

Finally, update the initramfs:
    
    $ sudo update-initramfs -u


### B) Using a key file on removable storage

The following steps assume that the removable drive is plugged into the server. Replace `sdX1` with the device node representing the key drive. 

##### Optional: encrypt the flash drive (two-factor authentication)

These commands will format the key drive with ext3 on top of LUKS and mount the encrypted device to `/mnt/keydrive`. Enter the passphrase when prompted.

    $ sudo cryptsetup luksFormat /dev/sdX1
    $ sudo cryptsetup luksOpen /dev/sdX1 encryptedkeydrive
    $ sudo mkfs.ext3 /dev/mapper/encryptedkeydrive
    $ sudo mkdir -p /mnt/keydrive
    $ sudo mount /dev/mapper/encryptedkeydrive /mnt/keydrive

Mount the keydrive (skip if you already mounted an encrypted key drive above).

    $ sudo mkdir -p /mnt/keydrive
    $ sudo mount /dev/sdX1 /mnt/keydrive

Create a key file and add it to the key pool of the root partition, then unmount the key drive. Note: replace `sda5` with the device node representing your root partition.

    $ sudo dd if=/dev/urandom of=/mnt/keydrive/.keyfile bs=1024 count=4
    $ sudo chmod 0400 /mnt/keydrive/.keyfile
    $ sudo cryptsetup luksAddKey /dev/sda5 /mnt/keydrive/.keyfile
    $ sudo umount /mnt/keydrive

Now edit `/etc/crypttab` to point to the `luks-unlock.sh` key script and let it know you are looking for a file named `.keyfile`. The entry should look similar to this:

    sda5_crypt UUID=44395a32-d586-4f55-9b16-163ab0f415cb .keyfile luks,keyscript=/usr/local/sbin/luks-unlock.sh

Add modules that may be needed to read the key drive to `/etc/initramfs-tools/modules`

    vfat
    fat
    nls_cp437
    nls_iso8859_1
    nls_utf8
    nls_base

Finally, update the initramfs:
    
    $ sudo update-initramfs -u
