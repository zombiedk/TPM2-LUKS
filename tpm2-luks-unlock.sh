#!/bin/bash
# Full disk encryption unlock via TPM2 chip on Linux using LUKS+TPM2
#
# Heavily modified, but based on:
# https://run.tournament.org.il/ubuntu-18-04-and-tpm2-encrypted-system-disk/
#
# Usage:
# sudo ./tpm2-luks-autounlock.sh [<device path>]
#
# e.g. to use the first device from /etc/crypttab:
# sudo ./tpm2-luks-autounlock.sh
#
# or to specify a device:
# sudo ./tpm2-luks-autounlock.sh /dev/sda3

KEYSIZE=64
KEYFILE=/root/.tpm2.key
KEYADDRESS=0x1500016

CheckIfRoot () {
	# Check if running as root
	if [ "$EUID" != 0 ]; then
		echo "This script must run with root privileges, e.g.:"
		echo "sudo $0"
		exit 1
	fi
}

ArgumentHandeling () {
	# If no parameter provided, get the first volume in crypttab and look up the device
	if [ $# -eq 1 ]
	then
		TARGET_DEVICE=$1
	else
		CRYPTTAB_VOLUME=$(head --lines=1 /etc/crypttab | awk '{print $1}')
		if [ -z "$CRYPTTAB_VOLUME" ]
		then
			echo "No device specified at the command line, and couldn't find one on the first line of /etc/crypttab.  Exiting with no changes made to the system."
			exit 1
		fi
		TARGET_DEVICE=$(cryptsetup status "$CRYPTTAB_VOLUME" | awk '/device:/ {print $2}')
	fi
	# remove /dev/ from device name
	DEVICE=${TARGET_DEVICE##*/}
}

CheckTPM2Chip () {
	if [ ! -c /dev/tpmrm0 ]
	then
		echo "ERROR TPM2 Chip not detected"
		exit 1
	fi
}

CheckDependencies () {
	if ! command -v cryptsetup &> /dev/null
	then
		echo "cryptsetup-bin could not be found"
		echo "Please install it with"
		echo "apt-get install cryptsetup-bin"
		exit 1
	fi

	if ! command -v mkinitramfs &> /dev/null
	then
		echo "mkinitramfs could not be found"
		echo "Please install it with"
		echo "apt-get install initramfs-tools-core"
		exit 1
	fi

	if ! command -v tpm2_nvread &> /dev/null
	then
		echo "tpm2_nvread could not be found"
		echo "Please install it with"
		echo "apt-get install tpm2-tools"
		exit 1
	fi

	if ! command -v sed &> /dev/null
	then
		echo "sed could not be found"
		echo "Please install it with"
		echo "apt-get install sed"
		exit 1
	fi
}

KeyFileGenerate () {
	if [ -f $KEYFILE ]
	then
		echo "Key file $KEYFILE already exists"
	else
		echo "Generating a $KEYSIZE char alphanumeric key and saving it to $KEYFILE..."
		echo
		tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$KEYSIZE" > "$KEYFILE"
	fi
}

KeyFileRemove () {
	echo "Removing $KEYFILE file for extra security..."
	echo
	shred -n 10 -u "$KEYFILE"
}

TPM2LuksCheck () {
	echo "Check where the TPM2 key already exist in LUKS"
	echo
	if tpm2_nvread -s "$KEYSIZE" "$KEYADDRESS" 2> /dev/null |cryptsetup open --test-passphrase "$TARGET_DEVICE" 2> /dev/null
	then
		echo "The TPM2 key is already defined in LUKS no changes needed"
		exit 0
	fi
}

TPM2Init () {
	echo "Defining the area on the TPM where we will store a $KEYSIZE character key..."
	echo
	tpm2_nvundefine "$KEYADDRESS" 2> /dev/null
	tpm2_nvdefine -s "$KEYSIZE" "$KEYADDRESS" > /dev/null
}

TPM2Write () {
	echo "Storing the key in the TPM..."
	echo
	tpm2_nvwrite -i "$KEYFILE" "$KEYADDRESS"
}

TPM2Verify () {
	echo "Checking the saved key against the one in the TPM..."
	echo
	if ! tpm2_nvread -s "$KEYSIZE" "$KEYADDRESS" 2> /dev/null | diff "$KEYFILE" - > /dev/null
	then
		echo "The $KEYFILE file does not match what is stored in the TPM.  Cannot proceed!"
		exit 1
	fi
}

LuskDriveCheck () {
	if cryptsetup isLuks "$TARGET_DEVICE"
	then
		echo "Using \"$TARGET_DEVICE\", which appears to be a valid LUKS encrypted device..."
	else
		echo "Device \"$TARGET_DEVICE\" does not appear to be a valid LUKS encrypted device.  Please specify a device on the command line, e.g."
		echo "sudo ./tpm2-luks-autounlock.sh /dev/sda3"
		exit 1
	fi
}

LuksAddKey () {
	echo "Adding the new key to LUKS.  You will need to enter the current passphrase used to unlock the drive..."
	echo
	if ! cryptsetup luksAddKey "$TARGET_DEVICE" "$KEYFILE"
	then
		echo "Something went wrong adding the encryption key to $TARGET_DEVICE."
		echo "Check /etc/crypttab and/or lsblk to determine your encrypted volume, then update this script with the correct value"
		exit 1
	fi
}

LuksVerify () {
	echo "Checking the saved key against the one in the LUKS2..."
	echo
	if ! cryptsetup open --test-passphrase "$TARGET_DEVICE" < "$KEYFILE"
	then
		echo "The $KEYFILE file is not found in LUKS. Cannot proceed!"
		exit 1
	fi
}

TPM2GetKeyInstall () {
	echo "Creating a key recovery script and putting it at /usr/local/sbin/tpm2-getkey..."
	echo
	cat << EOF > /usr/local/sbin/tpm2-getkey
#!/bin/sh
TMP_FILE=".tpm2-getkey.\$CRYPTTAB_NAME.tmp"

if [ -f "\$TMP_FILE" ]
then
	# tmp file exists, meaning we tried the TPM this boot, but it didn’t work for the drive and this must be the second
	# or later pass for the drive. Either the TPM is failed/missing, or has the wrong key stored in it.
	/lib/cryptsetup/askpass "Automatic disk unlock via TPM failed for (\${CRYPTTAB_SOURCE}) Enter passphrase: "
	exit
fi

# No tmp, so it is the first time trying the script. Create a tmp file and try the TPM
touch \${TMP_FILE}
tpm2_nvread -s $KEYSIZE $KEYADDRESS
EOF

# Move the file, set the ownership and permissions
# chown root: /usr/local/sbin/tpm2-getkey
chmod 750 /usr/local/sbin/tpm2-getkey
}

TPM2DecryptKeyInstall () {
	echo "Creating initramfs hook and putting it at /etc/initramfs-tools/hooks/tpm2-decryptkey..."
	echo
	cat << EOF > /etc/initramfs-tools/hooks/tpm2-decryptkey
#!/bin/sh
PREREQ=""
prereqs()
{
	echo "\${PREREQ}"
}
case \$1 in
	prereqs)
		prereqs
		exit 0
		;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec \`which tpm2_nvread\`
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0.0.0
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0
exit 0
EOF

# Move the file, set the ownership and permissions
# chown root: /etc/initramfs-tools/hooks/tpm2-decryptkey
chmod 755 /etc/initramfs-tools/hooks/tpm2-decryptkey
}

Crypttab () {
	if grep -F -q tpm2-getkey /etc/crypttab
	then
		echo "/etc/crypttab already has an entry for tpm2-getkey"
		if grep -F tpm2-getkey /etc/crypttab|grep -q "$DEVICE"
		then
			echo "No changes needed"
			exit 0
		else
			echo "ERROR: please manualy check that it is correct"
			echo "# e.g. this line: $DEVICE UUID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX none luks,discard"
			echo "# should become : $DEVICE UUID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX none luks,discard,keyscript=/usr/local/sbin/tpm2-getkey"
			echo ""
			echo "to enable tpm2 support in the boot loader you also must run this command to update initramfs"
			echo "cp /boot/initrd.img-\"$(uname -r)\" /boot/initrd.img-\"$(uname -r)\".orig"
			echo "mkinitramfs -o /boot/initrd.img-\"$(uname -r)\" \"$(uname -r)\""
			exit 1
		fi
	fi

	# This will only update the first line of /etc/crypttab.  If multiple updates are needed, they must be done manually.
	if [ "$(wc -l < /etc/crypttab)" -gt 1 ]
	then
		echo "This section only update the first line of /etc/crypttab. It seems there are multiple lines, so please update the file manually."
		echo "# e.g. this line: $DEVICE UUID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX none luks,discard"
		echo "# should become : $DEVICE UUID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX none luks,discard,keyscript=/usr/local/sbin/tpm2-getkey"
		echo ""
		echo "to enable tpm2 support in the boot loader you also must run this command to update initramfs"
		echo "cp /boot/initrd.img-\"$(uname -r)\" /boot/initrd.img-\"$(uname -r)\".orig"
		echo "mkinitramfs -o /boot/initrd.img-\"$(uname -r)\" \"$(uname -r)\""
		exit 1
	fi

	echo "Backing up /etc/crypttab to /etc/crypttab.bak, then updating it to run tpm2-getkey on decrypt..."
	echo
	cp /etc/crypttab /etc/crypttab.bak
	sed -i 's%$%,keyscript=/usr/local/sbin/tpm2-getkey%' /etc/crypttab

	echo "Copying the current initramfs just in case, then updating the initramfs with auto unlocking from the TPM..."
	echo
	cp /boot/initrd.img-"$(uname -r)" /boot/initrd.img-"$(uname -r)".orig
	mkinitramfs -o /boot/initrd.img-"$(uname -r)" "$(uname -r)"
}

InfoMsg () {
	echo "At this point you are ready to reboot and try it out!"
	echo
	echo "If the drive unlocks as expected, you may optionally remove the original password used to encrypt the drive and rely"
	echo "completely on the random new one stored in the TPM.  If you do this, you should keep a copy of the key somewhere saved on"
	echo "a DIFFERENT system, or printed and stored in a secure location on another system so you can manually enter it at the prompt."
	echo "To get a copy of your key for backup purposes, run this command:"
	echo "tpm2_nvread -s $KEYSIZE $KEYADDRESS"
	echo
	echo "If you remove the original password used to encrypt the drive and fail to backup the key in then TPM then experience TPM,"
	echo "motherboard, or another failure preventing auto-unlock, you WILL LOSE ACCESS TO EVERYTHING ON THE DRIVE!"
	echo "If you are SURE you have a backup of the key you put in the TPM, here is the command to remove the original password:"
	echo "cryptsetup luksRemoveKey $TARGET_DEVICE"
	echo
	echo "If booting fails, press esc at the beginning of the boot to get to the grub menu.  Edit the Ubuntu entry and add .orig to end"
	echo "of the initrd line to boot to the original initramfs this one time."
	echo "e.g. initrd /initrd.img-5.4.0-40-generic.orig"
}


# Script start here, everything above if definations of bash funktions

# Fail if not run as ROOT
CheckIfRoot

# Check if TPM2 chip exists
CheckTPM2Chip

# Check witch arguments the script is called with
ArgumentHandeling "$@"

# Check that the required apps are installed
CheckDependencies

# Check where we have a LUKS drive
LuskDriveCheck

# Check if TPM2 chip already have a key that can be used to unlock drive
TPM2LuksCheck

# Prepare TPM2 chip
TPM2Init

# Generate a random key
KeyFileGenerate

# Write key to TPM2 chip
TPM2Write

# Check that key has been stored in TPM2 correctly
TPM2Verify

# Add key to LUKS2 volume
LuksAddKey

# Check that key has been storted in LUKS correctly
LuksVerify

# Remove key file
KeyFileRemove

# Generate script
TPM2GetKeyInstall

# Generate script
TPM2DecryptKeyInstall

# Update crypttab
Crypttab

# Display final information
InfoMsg
