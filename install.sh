#!/usr/bin/env bash

retry() {
    until $@
    do
        echo "Try again"
    done
}

format_disk() {
    echo "Formatting the provided disk"
    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk -W always ${TARGET_DISK}
  g    # create empty gpt label
  n    # boot partition
       # default partnumber
       # default - start at beginning of disk
  +1G  # 1G boot parttion
  n    # efi partition
       # default partnumber
       # default, start immediately after preceding partition
  +1G  # default, extend partition to end of disk
  n    # swap partition
       # default partnumber
       # default start immediately after preceding partition
  +16G # 16G swap, we don't need suspend to disk
  n    # luks crypt partition
       # default partnumber
       # default, start immediately after preceding partition
       # default, extend to the end of the disk
  w    # write to disk
  q    # and we're done
EOF
}

set_partition_variables () {
    export BOOT_PARTITION=$(lsblk -p -o NAME --json  | jq '.blockdevices | map(select(.name == '\"${TARGET_DISK}\"')) | .[].children | .[0].name' | sed 's/"//g')
    export EFI_PARTITION=$(lsblk -p -o NAME --json  | jq '.blockdevices | map(select(.name == '\"${TARGET_DISK}\"')) | .[].children | .[1].name' | sed 's/"//g')
    export SWAP_PARTITION=$(lsblk -p -o NAME --json  | jq '.blockdevices | map(select(.name == '\"${TARGET_DISK}\"')) | .[].children | .[2].name' | sed 's/"//g')
    export LUKS_PARTITION=$(lsblk -p -o NAME --json  | jq '.blockdevices | map(select(.name == '\"${TARGET_DISK}\"')) | .[].children | .[3].name' | sed 's/"//g')

    export LUKS_NAME=aska_crypt
}

create_and_mount_filesystems() {
    echo "$LUKS_PASS" | cryptsetup -q luksFormat $LUKS_PARTITION

    echo "$LUKS_PASS" | cryptsetup luksOpen $LUKS_PARTITION $LUKS_NAME

    mkfs.btrfs -f $BOOT_PARTITION
    mount $BOOT_PARTITION /mnt
    btrfs subvolume create /mnt/boot
    umount /mnt

    mkfs.vfat -F32 $EFI_PARTITION

    mkfs.btrfs -f /dev/mapper/$LUKS_NAME
    mount /dev/mapper/$LUKS_NAME /mnt
    btrfs subvolume create /mnt/home
    btrfs subvolume create /mnt/root
    umount /mnt

    mount -o subvol=root /dev/mapper/$LUKS_NAME /mnt

    mkdir /mnt/{home,boot}

    mount -o subvol=home /dev/mapper/$LUKS_NAME /mnt/home
    mount -o subvol=boot $BOOT_PARTITION /mnt/boot

    mkdir /mnt/boot/efi

    mount $EFI_PARTITION /mnt/boot/efi

    # Mark the swap partition with cryptswap label so that it can be mount persistently
    mkfs.ext2 -L cryptswap $SWAP_PARTITION 1M
}

base_install() {
    # Simple installation process written for my needs. It is assumed that the script is run
    # when an internet connection already exist.
    echo "Getting jq."
    curl -o jq -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64
    install -m777 jq /usr/local/bin/jq

    format_disk

    set_partition_variables

    create_and_mount_filesystems

    PKG_LIST="base base-devel linux linux-firmware btrfs-progs man-db man-pages texinfo \
          networkmanager sway swaylock swayidle slurp bemenu alacritty waybar grim \
          mako wallutils xorg-xwayland grub efibootmgr light wireguard-tools \
          intel-ucode mlocate alsa-utils pulseaudio keepassxc gimp krita inkscape \
          libreoffice thunderbird docker mc htop neofetch sxiv tor \
          torbrowser-launcher mpd ncmpcpp mpv youtube-dl rtorrent wget electrum \
          telegram-desktop signal-desktop ardour ffmpeg zathura cmake tmux git \
          zbar hledger bat ripgrep exa fd cryptsetup jq inetutils ttc-iosevka \
          otf-font-awesome curl wget"
    pacstrap /mnt $(echo $PKG_LIST)

    genfstab -U /mnt > /mnt/etc/fstab

    # Enable cryptswap mount on boot
    echo -e "swap\tLABEL=cryptswap\t/dev/urandom\tswap,offset=2048,cipher=aes-xts-plain64,size=512" >> /mnt/etc/crypttab
    echo -e "/dev/mapper/swap\tnone\tswap\tdefaults\t0 0" >> /mnt/etc/fstab

    cp $SCRIPT /mnt/install.sh

    arch-chroot /mnt /bin/bash -c "/install.sh --stage=chroot --disk=$TARGET_DISK --root-pass=$ROOT_PASS --user-pass=$USER_PASS"

    rm /mnt/install.sh

    umount -R /mnt
    cryptsetup luksClose $LUKS_NAME
    reboot
}


chroot() {
    set_partition_variables
    # Edit hooks
    sed -i 's/^HOOKS/#HOOKS/g' /etc/mkinitcpio.conf
    echo "HOOKS=(base udev autodetect modconf block encrypt filesystems btrfs keyboard fsck)" >> /etc/mkinitcpio.conf
    mkinitcpio -P

    # Edit /etc/default/grub
    LUKS_UUID=$(lsblk -p -o NAME --json  | jq '.blockdevices | map(select(.name == '\"${TARGET_DISK}\"')) | .[].children | .[3].name' | sed 's/"//g' | xargs blkid -o value -s UUID)
    sed -i "/GRUB_CMDLINE_LINUX=\"\"/ c\GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:${LUKS_NAME}\"" /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch
    grub-mkconfig -o /boot/grub/grub.cfg

    systemctl enable NetworkManager
    systemctl enable docker

    WINE="wine"
    # Edit pacman.conf (enable multilibe)
    echo -e "[multilib]\nInclude = /etc/pacman.d/mirrorlist\n" >> /etc/pacman.conf
    echo "keyserver hkp://keyserver.ubuntu.com" >> /etc/pacman.d/gnupg/gpg.conf
    pacman -Sy --noconfirm "$WINE"

    ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    echo nerv > /etc/hostname

    # Edit sudoers
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

    # Edit locale.gen
    sed -i "s/#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
    sed -i "s/#ru_RU.UTF-8/ru_RU.UTF-8/" /etc/locale.gen
    locale-gen
    echo LANG=en_US.UTF-8 > /etc/locale.conf

    # Set root password
    echo "Setting root password: "
    chpasswd <<< "root:$ROOT_PASS"

    # Create user, add him to appropriate groups, set password
    useradd -m -G wheel,video,docker danberdev
    echo "Setting user password: "
    chpasswd <<< "danberdev:$USER_PASS"



    su danberdev -c "if [[ ! -d ~/.gnupg ]]; then mkdir ~/.gnupg; chmod 700 ~/.gnupg; fi"
    su danberdev -c 'echo "keyserver hkp://keyserver.ubuntu.com" > ~/.gnupg/gpg.conf'

    su danberdev -c 'cd /tmp && git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si'


    AUR_LIST="emacs-gcc-wayland-devel-bin brave-bin ssss eddie-cli freenet i2p \
              electrum-dash slack-desktop pacmixer loc ttf-iosevka-term"
    su danberdev -c "paru -Sy --noconfirm $AUR_LIST"

    su danberdev -c 'cd /tmp && git clone https://github.com/danberdev/dotfiles && cd dotfiles && ./scripts/deploy.sh'

    su danberdev -c 'git clone https://github.com/danberdev/emacs-config ~/.emacs.d'

    su danberdev -c "curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh"

    exit
}

export SCRIPT=$(readlink -f $0)

for i in "$@"
do
    case $i in
        # The disk where the system will be installed
        -d=*|--disk=*)
            export TARGET_DISK="${i#*=}"
            ;;

        # Installation stages, so that the script will be able
        # to continue running in chroot
        -s=*|--stage=*)
            export STAGE="${i#*=}"
            ;;

        -rp=*|--root-pass=*)
            export ROOT_PASS="${i#*=}"
            ;;

        -up=*|--user-pass=*)
            export USER_PASS="${i#*=}"
            ;;

        -lp=*|--luks-pass=*)
            export LUKS_PASS="${i#*=}"
            ;;

        -h|--help)
            echo "Usage: ./install.sh [options]"
            echo "-d  | --disk — specify disk where the system will be installed [required]"
            echo "-s  | --stage — specify installation stage. For internal usage"
            echo "-rp | --root-pass — specify root password [required]"
            echo "-up | --user-pass — specify user password [required]"
            echo "-lp | --luks-pass — specify luks password [required]"
            echo "-h  | --help — print this message"
            exit
            ;;

        *)
            # unknown option
            ;;
    esac
done

if [[ -z $USER_PASS || -z $LUKS_PASS || -z $ROOT_PASS || -z $TARGET_DISK ]]; then
    echo "Please, check ./install.sh -h for options. Didn't provide all needed options!"
    exit
fi

if [[ -z $STAGE ]]; then STAGE="base"; fi
case $STAGE in
    "base")
        base_install
        ;;

    "chroot")
        chroot
        ;;
esac
