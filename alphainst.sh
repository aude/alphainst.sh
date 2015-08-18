#!/usr/bin/bash

# -------------------------------
# ----------- License -----------
# -------------------------------
# @licstart
# Copyright (C) 2014-toyear  aude
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# @licend
# -------------------------------
# ----------- License -----------
# -------------------------------

# -------------------------------
# ------------ TODO -------------
# -------------------------------
# - implement UEFI booting
# - os probing (os-prober http://anonscm.debian.org/gitweb/?p=d-i/os-prober.git;a=blob_plain;f=README;hb=HEAD)
# - create drop-down field (yad --text-info --tail --listen) showing console output (`script`)
# - uuidgen for sgdisk? so one is certain about the UUID the newly created partition has been assigned
# - make partition selection dialog only contain partitions of selected disk
#   must be dynamic. ie. when one changes install disk choice, available partitions must be updated
#     compatible with loop devs?
# - validate more shizz
# - maybe make it more suited to install to UEFI without cleaning disk
# - maybe move to UUIDs?
# - would be nice to migrate yad lists to --list. but it seems yad supports opnly one list per dialog.
# - aesthetics :)
# -------------------------------
# ------------ TODO -------------
# -------------------------------

# -------------------------------
# ------------ Init ------------- 
# -------------------------------
# read local functions
. /etc/rc.d/functions
. /etc/os-release
# -------------------------------
# ------------ Init ------------- 
# -------------------------------

# -------------------------------
# ---------- Variables ----------
# -------------------------------
version='0.16'
# format: 'package:file-to-test-for another-package:file-tested-with-which-command'
dependencies='gptfdisk:sgdisk syslinux:syslinux dosfstools:mkfs.fat mtools:mtools'

installDisk=
rootMount='/mnt/inst'
rootPart=
alphaOSDir='/alphaos.usb'
alphaOSInstPath="${rootMount}${alphaOSDir}"
biosPart=
ESPMount='/mnt/boot/efi'
ESP=
syslinuxCfgDir='/boot/syslinux'
syslinuxCfgPath="${rootMount}${syslinuxCfgDir}"
syslinuxCfgFile="${syslinuxCfgPath}/syslinux.cfg"

alphaOSSrcDir='/mnt/live/memory/data/alphaos'
if [ ! -d "${alphaOSSrcDir}" ]; then
    alphaOSSrcDir='/mnt/home/alphaos'
fi
# try drastic methods to find alphaOS files
if [ ! -d "${alphaOSSrcDir}" ]; then
    findOut="$(find /mnt/live/memory/data/ -name alpha_${VERSION}.sb | head -n 1)"
    if [ -n "${findOut}" ]; then
        alphaOSSrcDir="${findOut%/*}"
    fi
fi
# 4 required files, and empty modules dir
alphaOSFiles=("/alpha_${VERSION}.sb" "/extra_${VERSION}.sb" '/boot/initrfs.img' '/boot/vmlinuz' '/modules/')

# dialog
dialog="$(which yad)"
# YAD
dtitle="--title=${0##*/}"
# need to run fixed, as YAD behaves weirdly, adding lots of newlines.
dsettings='--center --fixed --borders=8 --always-print-result --selectable-labels --window-icon=drive-harddisk'
dialog="${dialog} ${dtitle} ${dsettings}"
dyescode=90
dyes="--button=gtk-yes:${dyescode}"
dnocode=91
dno="--button=gtk-no:${dnocode}"
dokcode=92
dok="--button=gtk-ok:${dokcode}"
dhomecode=98
dhome="--button=gtk-home:${dhomecode}"
dquitcode=99
dquit="--button=gtk-quit:${dquitcode}"
# -------------------------------
# ---------- Variables ----------
# -------------------------------

# -------------------------------
# ---------- Functions ----------
# -------------------------------

# console echo functions
# $1 = msgtype, see below
# $2 = msg
cinform () {
    # process msgtype
    local prefixColour
    case ${1} in
        header) prefixColour=${BGreen};;
        info) prefixColour=${BWhite};;
        warning) prefixColour=${BYellow};;
        error) prefixColour=${BRed};;
        *) prefixColour=${BWhite};;
    esac
    
    echo -e ${prefixColour}'==> '${BWhite}"${2}"${Color_Off}
}

# dialog functions
# $@ = msg[ additional parameters]
dinform () {
    ${dialog} ${dok} --text="${1}"
    return ${?}
}

# $@ = msg[ additional parameters]
dwarn () {
    ${dialog} --image='dialog-warning' ${dok} --text="${@}"
}

# $@ = msg[ additional parameters]
derror () {
    ${dialog} --image='dialog-error' ${dok} --text="${@}"
}

# $@ = [warn ]msg[ additional parameters]
dask () {    
    # will we warn, respectively?
    local img
    local btnParams
    # default to just ask
    img='dialog-question'
    btnParams="${dyes} ${dno}"
    if [ "${1}" = 'warn' ]; then
        img='dialog-warning'
        btnParams="${dno} ${dyes}"
        shift
    fi
    
    ${dialog} --image=${img} ${btnParams} --text="${@}"
    return ${?}
}

priv_check () {
if [ ${EUID} -ne 0 ]; then
    cinform error "This script must be run as root. Type in 'su -c ${0}' to run it as root."
    if [ -n "${dialog}" ]; then
        dinform "This script must be run as root.\nType 'su -c ${0}' in a terminal to run it as root."
    fi
    exit 1
fi
}

escape_for_sed () {
#~ # sed it like a boss \/
#~ echo $(echo ${1} | sed -e 's/\//\\\\\//g')
# sed it like a pro -.- ~https://stackoverflow.com/questions/407523/escape-a-string-for-a-sed-replace-pattern
echo $(echo ${1} | sed -e 's|[/&]|\\&|g')
}

dep_ensure () {
cinform header 'checking dependencies'

pkg=
prog=
pkgToInstall='BOGUS-START-VALUE'

# cannot proceed as long as dependencies are not met
while [ -n "${pkgToInstall}" ]; do
    # check if dependencies are met
    pkgToInstall=
    for dep in ${dependencies}; do
        pkg=$(echo ${dep} | cut -d ':' -f 1)
        prog=$(echo ${dep} | cut -d ':' -f 2)
        
        which ${prog} > /dev/null
        if [ "${?}" = 1 ]; then
            pkgToInstall+=" ${pkg}"
        fi
    done
    
    # install if anything to install
    if [ -n "${pkgToInstall}" ]; then
        cinform warning "missing${pkgToInstall}"
        # update pacman cache if we have to
        if [ ! -f /var/lib/pacman/sync/community.db ]; then
            pacman -Sy
        fi
        pacman -S ${pkgToInstall}
        
        # quit if user declined installation
        if [ ${?} == 1 ]; then
            cinform error 'cannot run without all dependencies'
            exit
        fi
    fi
done

cinform header 'all dependencies met'
}

get_dev_path () {
lsblk --noheadings --raw --paths --output NAME ${1}
}

get_part_by_partlabel () {
# yeah, it's getting rough. please, enlighten me the right way to do stuff :D
lsblk --noheadings --raw --paths --output NAME,PARTLABEL | sed 's/\\x20/ /g' | grep "${1}" | cut -d ' ' -f 1
}

# $1 = sgdisk output
get_partnum_from_sgdiskoutput () {
# process sgdisk output, looking for 'partNum is n', where we get n.
# sgdisk counts from 0, whereas Linux counts from 1
sgp=$(echo "${1}" | grep --ignore-case --only-matching --extended-regexp 'partNum is [0-9]+' | awk '{print $3}')
sgp=$(( ${sgp} + 1 ))
echo ${sgp}
}

# $1 = mount point
# $2 = partition path
mount_part () {
cinform info "mounting ${1} on ${2}"
mkdir -p ${2}
mount ${1} ${2}
}

unmount_dir () {
sync
cinform info "unmounting ${1}"
umount ${1}
rmdir ${1}
}

# $1 = space separated dev list
# $2 = item to pre-select
process_devlist_for_yad () {
# get all devices, in format 'devpath (size)!devpath (size)!^prechosendevpath!et cetera'

devs="${1}"
devList=

if [ -n "${devs}" ]; then
    for dev in ${devs}; do
        # add device and it's size
        # yad delimiter is "!"
        devList="${devList}!${dev} ($(lsblk --nodeps --noheadings --raw --output SIZE ${dev}))"
    done
    #~ # cut first (blank) entry
    #~ devList=$(echo ${devList} | cut -d '!' -f 2-)
    # mark pre-chosen disk, if exists
    if [ -n "${2}" ]; then
        devList=$(echo ${devList} | sed "s/\($(escape_for_sed ${2})\)/\^\1/")
    fi
fi

echo ${devList}
}

get_disks () {
#~ devs=$(ls /dev/disk/by-uuid)
#~ devs=$(ls /dev/disk/by-id)
devs=$(lsblk --nodeps --noheadings --paths --raw --output NAME,TYPE | grep 'disk' | cut -d ' ' -f 1)

process_devlist_for_yad "${devs}" "${installDisk}"
}

get_partitions () {
devs=

# if install disk is chosen, only get partitions of install disk
# else, get all partitions, and exclude ones with irrelevant type. (disk, etc.)
#   this lines up well in a one-liner, as ${installDisk} will be an empty string if not set
#~ devs=$(lsblk --noheadings --paths --raw --output NAME,TYPE ${installDisk} | grep -E -v 'disk|rom' | cut -d ' ' -f 1)
devs=$(lsblk --noheadings --paths --raw --output NAME,TYPE ${installDisk} | grep 'part' | cut -d ' ' -f 1)

process_devlist_for_yad "${devs}" "${rootPart}"
}

get_ESPs () {
# try and get all EF00 parititons
# is Linux supposed to be this hacky? 8D
disks=$(lsblk --nodeps --noheadings --paths --raw --output NAME,TYPE | grep 'disk' | cut -d ' ' -f 1)
esps=

for disk in ${disks}; do
    for esp in $(sgdisk -p ${disk} | grep -i 'EF00' | awk '{print $1}'); do
        esps+="${disk}${esp}"
    done
done

process_devlist_for_yad "${esps}" "${ESP}"
}

install_disk_check  () {
if [ -z "${installDisk}" ]; then
    dinform 'you have to choose an install disk first'
    return 1
fi
}

install_part_check () {
if [ -z "${rootPart}" ]; then
    dinform 'you have to choose a partition for the alphaOS system files first'
    return 1
fi
}

uefi_part_check () {
if [ -z "${ESP}" ]; then
    dinform 'you have to choose an EFI System Partition for the UEFI files first'
    return 1
fi
}

prepare_disk () {
install_disk_check || return

dask warn "will now clean and format ${installDisk}\nALL DATA ON THIS DISK WILL BE ERASED\nare you sure you want to continue?"
if [ ${?} -eq ${dnocode} ]; then
    return
fi

# we use GPT. MBR belongs to the past.
# go for sgdisk
# ~ http://rodsbooks.com/gdisk/sgdisk-walkthrough.html
# clean disk
cinform header "cleaning ${installDisk} using sgdisk"
sgdisk --zap-all ${installDisk}

# this was needed for GRUB
if false; then
    # create BIOS boot partition
    dask 'would you like to create a BIOS boot partition,\nto be able to boot GRUB from BIOS systems?'
    if [ ${?} -eq ${dyescode} ]; then
        # 1007K value retrieved from Arch wiki
        biosPartSize='1007K'
        biosPartLabel='BIOS boot partition'
        
        cinform header "creating ${biosPartSize} BIOS boot partition on ${installDisk}"
        
        # capture stdout, to get the partNum of the created partition
        # create a fd, which just redirects to stdout
        exec 5>&1
        sgdiskOut=$(sgdisk --new=0:0:+${biosPartSize} --change-name=0:"${biosPartLabel}" --typecode=0:ef02 ${installDisk} | tee >(cat - >&5))
        exec 5>&-
        
        # record BIOS boot partition
        # is it always analogous to ${installDisk}(${partNum}+1)?
        biosPart=${installDisk}$(get_partnum_from_sgdiskoutput "${sgdiskOut}")
        #~ biosPart=$(get_part_by_partlabel "${biosPartLabel}")
        
        sync
    fi
fi

# create EFI System Partition
dask 'would you like to create an EFI System Partition,
to be able to boot from UEFI systems?

note: UEFI Secure Boot is not supported by alphainst.sh as of today.'
if [ ${?} -eq ${dyescode} ]; then
    ESPLabel='EFI System Partition'
    # recommended size is 512M, but how low can we go?
    #~ efiPartSize='512M'
    # 32MB is minimum size for FAT, go just above
    efiPartSize='33M'
    
    cinform header "creating ${efiPartSize} EFI System Partition on ${installDisk}"
    
    exec 5>&1
    sgdiskOut=$(sgdisk --new=0:0:+${efiPartSize} --change-name=0:"${ESPLabel}" --typecode=0:ef00 ${installDisk} | tee >(cat - >&5))
    exec 5<&-
    
    ESP=${installDisk}$(get_partnum_from_sgdiskoutput "${sgdiskOut}")
    
    sync
    
    cinform header "formatting EFI System Partition (${ESP}) as FAT32"
    mkfs.fat -F 32 ${ESP}
    sync
    
    # inform that there is no automatic install for this as of today
    dinform 'alphainst.sh does not currently install UEFI booting for you,\nyou can install it manually'
fi

# create data partition
dask "would you like to create a data partition,\nto store, amongst whatever you'd like, alphaOS system files?"
if [ ${?} -eq ${dyescode} ]; then
    rootPartLabel='data'
    
    cinform header "creating data partition of remaining space on ${installDisk}"
    
    exec 5>&1
    sgdiskOut=$(sgdisk --new=0:0:0 --change-name=0:"${rootPartLabel}" --typecode=0:8300 ${installDisk} | tee >(cat - >&5))
    exec 5<&-

    # record root partition
    rootPart=${installDisk}$(get_partnum_from_sgdiskoutput "${sgdiskOut}")
    
    sync

    cinform header "formatting data partition (${rootPart}) as FAT32"
    mkfs.fat -F 32 ${rootPart}
    sync
fi
}

alpha_inst () {
install_part_check || return

# copy alphaOS files
if [ ! -d "${alphaOSSrcDir}" ]; then
    cinform error "could not find alphaOS system files\n    please copy them manually to ${alphaOSInstPath}"
    derror "could not find alphaOS system files\nplease copy them manually to ${alphaOSInstPath}"
    return 1
fi

${dialog} --text="do you want to copy all files from ${alphaOSSrcDir},\nor create a fresh install?" \
--button={'all files:2','fresh install:3'} ${dhome}
retVal=${?}

# mount root partition
mount_part ${rootPart} ${rootMount}

case ${retVal} in
2)
    cinform header "copying ${alphaOSSrcDir} to ${alphaOSInstPath}"
    cp -fvR ${alphaOSSrcDir} "${alphaOSInstPath}"
    ;;
3)
    cinform header "copying base system files from ${alphaOSSrcDir} to ${alphaOSInstPath}"
    len=${#alphaOSFiles[@]}
    file=
    
    for (( i=0; i < ${len}; i++ )); do
        file=${alphaOSFiles[${i}]}
        
        # must create directory of file first
        fileDir="$(echo "${alphaOSInstPath}${file}" | sed -r 's/\/[^\/]+$//')"
        mkdir -pv "${fileDir}"
        cp -fv {"${alphaOSSrcDir}","${alphaOSInstPath}"}"${file}"
    done
    ;;
${dhomecode})
    return
    ;;
esac

# clean up
unmount_dir ${rootMount}
}

syslinux_bios_inst () {
# check ArchWiki#SYSLINUX for docs
install_disk_check || return
install_part_check || return

dask warn "will now install SYSLINUX for BIOS at ${installDisk} and data files at ${rootPart}\nALL BOOT LOADER DATA ON THIS DISK WILL BE ERASED\n   (probably not so scary ;)\nare you affirmative you want to continue?"
if [ ${?} -eq ${dnocode} ]; then
    return
fi

cinform header 'installing SYSLINUX for BIOS'

mount_part ${rootPart} ${rootMount}

syslinuxLib='/usr/lib/syslinux/bios'
syslinuxMbr="${syslinuxLib}/gptmbr.bin"

mkdir -p ${syslinuxCfgPath}
cinform header "copying SYSLINUX Comboot modules (*.c32) to ${syslinuxCfgPath}"
cp ${syslinuxLib}/*.c32 ${syslinuxCfgPath}
sync

cinform header "installing SYSLINUX to ${syslinuxCfgPath} of ${rootPart}"
syslinux --install --directory ${syslinuxCfgDir} ${rootPart}

cinform header "marking ${rootPart} as active (legacy_boot GPT flag)"
rootPartNum=$(echo "${rootPart}" | grep -o '[0-9]\+$')
sgdisk ${installDisk} --attributes=${rootPartNum}:set:2
sgdisk ${installDisk} --attributes=${rootPartNum}:show

cinform header "dd'ing ${syslinuxMbr} MBR to ${installDisk}"
dd bs=440 count=1 conv=notrunc if=${syslinuxMbr} of=${installDisk}

unmount_dir ${rootMount}

dinform 'remember to configure SYSLINUX :)'
}

syslinux_uefi_inst () {
# no support yet
# the challenge is yours :)

dinform 'UEFI support is not implemented yet.
the challenge is yours! :D

following is a sample dialog.
there is lots of information in the code!'

# following is sample code
# TODO: remove bogus above

# early support, syslinux UEFI support is itself preliminary, no guarantees

# -- UEFI
# ~Wikipedia: UEFI, EFI System Partition
# ~Arch Wiki: Syslinux#UEFI
# ~Arch Wiki: GRUB#UEFI
# ~https://wiki.gentoo.org/wiki/GRUB2#UEFI.2FGPT
# ~https://www.gnu.org/software/grub/manual/grub.html
# -- Secure Boot
# ~http://www.rodsbooks.com/efi-bootloaders/secureboot.html
# ~https://www.suse.com/communities/conversations/uefi-secure-boot-details/
# ~http://www.zdnet.com/torvalds-clarifies-linuxs-windows-8-secure-boot-position-7000011918/
# ~http://www.zdnet.com/shimming-your-way-to-linux-on-windows-8-pcs-7000008246/
# ~https://wiki.ubuntu.com/SecurityTeam/SecureBoot

uefi_part_check || return
install_part_check || return

echo \
'http://www.rodsbooks.com/efi-bootloaders/secureboot.html
https://fsf.org/campaigns/secure-boot-vs-restricted-boot/
http://www.zdnet.com/torvalds-clarifies-linuxs-windows-8-secure-boot-position-7000011918/
https://wiki.ubuntu.com/SecurityTeam/SecureBoot' | \
dask warn \
"UEFI Secure Boot is not supported by alpha_inst.sh as of today.
this has been chosen as a user should not be forced to trust anyone
in order to boot their programs.

meanwhile, regular UEFI booting is definitely supported :)
you just need to disable Secure Boot in your firmware,
or look up other means to boot alphaOS if you require Secure Boot.
look it up in any case.

will now install SYSLINUX for UEFI at ESP ${ESP} and data files at ${rootPart}
is your mind set about continuing?

the web is full of details. exempli gratia:" --text-info --show-uri
if [ ${?} -eq ${dnocode} ]; then
    return
fi

# we need to return for now
return

cinform header 'installing SYSLINUX for UEFI'

# at least, need ESP for UEFI files
mount_part ${ESP} ${ESPMount}

# TODO

# TODO

unmount_dir ${ESPMount}

dinform 'remember to configure SYSLINUX :)'
}

grub_uefi_inst () {
# the earlier GRUB install, you can look here if you really need UEFI booting
# if so, have a look at the doc mentioned in syslinux_uefi_inst
cinform header 'installing GRUB for UEFI'

# need ESP for UEFI files and root partition for /boot folder
mount_part ${ESP} ${ESPMount}
mount_part ${rootPart} ${rootMount}

cinform header 'installing GRUB --target=x86_64-efi to EFI directory ${ESPMount} and data files to ${rootMount}'
# preload GPT, fat and video modules. consulting Arch Wiki#GRUB can be an idea for possible fixes
preloadEfiModules="part_gpt part_msdos fat all_video"
grub-install --target=x86_64-efi --efi-directory=${ESPMount} --bootloader-id=grub \
--root-directory=${rootMount} --recheck --removable --modules="${preloadEfiModules}"
sync

unmount_dir ${rootMount}
unmount_dir ${ESPMount}

dinform 'remember to configure GRUB :)'
}

syslinux_cfg () {
install_part_check || return

mount_part ${rootPart} ${rootMount}

# get UUID of root partition
rootPartUUID=`lsblk --noheadings --output UUID ${rootPart}`

dask warn "will now (over)write ${syslinuxCfgFile}\nare you in no doubt you want to continue?"
if [ ${?} -eq ${dnocode} ]; then
    unmount_dir ${rootMount}
    return
fi

cinform header 'configuring SYSLINUX'

cinform header "writing built-in SYSLINUX config to ${syslinuxCfgFile}"
cat << __SYSLINUXCFG__ > ${syslinuxCfgFile}
# SYSLINUX config. suit yourself
# https://wiki.archlinux.org/index.php/Syslinux
# http://www.syslinux.org/wiki/index.php/SYSLINUX#How_do_I_Configure_SYSLINUX.3F

PROMPT 0
TIMEOUT 16
# instant booting, unless Alt or Shift (ironically, doesn't work sometimes) is pressed
#MENU SHIFTKEY
# activate on hotkey press
MENU IMMEDIATE

UI menu.c32
#UI vesamenu.c32

MENU TITLE alphaOS
#MENU BACKGROUND bootsplash.png
# menu colors borrowed from Arch, thanks
MENU COLOR border       30;44   #40ffffff #a0000000 std
MENU COLOR title        1;36;44 #9033ccff #a0000000 std
MENU COLOR sel          7;37;40 #e0ffffff #20ffffff all
MENU COLOR unsel        37;44   #50ffffff #a0000000 std
MENU COLOR help         37;40   #c0ffffff #a0000000 std
MENU COLOR timeout_msg  37;40   #80ffffff #00000000 std
MENU COLOR timeout      1;37;40 #c0ffffff #00000000 std
MENU COLOR msg07        37;40   #90ffffff #a0000000 std
MENU COLOR tabmsg       31;40   #30ffffff #00000000 std

# what is booted when time runs out
DEFAULT alphausb

# of course, re-arrange these as you prefer
# and, of more course, mix and match kernel parameters as you'd like

LABEL alphausb
    MENU LABEL alphaOS GNU/Linux ^usbmode
    LINUX ${alphaOSDir}/boot/vmlinuz from=${alphaOSDir} fsck usbmode
    APPEND root=UUID=${rootPartUUID} rw
    INITRD ${alphaOSDir}/boot/initrfs.img

LABEL alpha
    MENU LABEL ^alphaOS GNU/Linux
    LINUX ${alphaOSDir}/boot/vmlinuz from=${alphaOSDir} fsck
    APPEND root=UUID=${rootPartUUID} rw
    INITRD ${alphaOSDir}/boot/initrfs.img

LABEL alphatoram
    MENU LABEL alphaOS GNU/Linux usbmode ^toram
    LINUX ${alphaOSDir}/boot/vmlinuz from=${alphaOSDir} fsck usbmode toram
    APPEND root=UUID=${rootPartUUID} rw
    INITRD ${alphaOSDir}/boot/initrfs.img

LABEL alphanoxorg
    MENU LABEL alphaOS GNU/Linux usbmode no^xorg
    LINUX ${alphaOSDir}/boot/vmlinuz from=${alphaOSDir} fsck usbmode noxorg
    APPEND root=UUID=${rootPartUUID} rw
    INITRD ${alphaOSDir}/boot/initrfs.img

LABEL alphadbg
    MENU LABEL alphaOS GNU/Linux usbmode ^debug
    LINUX ${alphaOSDir}/boot/vmlinuz from=${alphaOSDir} usbmode debug
    APPEND root=UUID=${rootPartUUID} rw
    INITRD ${alphaOSDir}/boot/initrfs.img

LABEL alphafresh
    MENU LABEL alphaOS GNU/Linux ^fresh
    LINUX ${alphaOSDir}/boot/vmlinuz from=${alphaOSDir} fresh
    APPEND root=UUID=${rootPartUUID} rw
    INITRD ${alphaOSDir}/boot/initrfs.img

MENU SEPARATOR

LABEL hd0
    MENU LABEL ^Continue to first hard disk
    COM32 chain.c32
    APPEND hd0

MENU SEPARATOR

LABEL hdt
    MENU LABEL ^HDT (Hardware Detection Tool)
    COM32 hdt.c32

LABEL reboot
    MENU LABEL ^Reboot
    COM32 reboot.c32

LABEL poweroff
    MENU LABEL ^Poweroff
    COM32 poweroff.c32
__SYSLINUXCFG__
sync

# open in text editor for interactivity and transparency
if [ -n "${EDITOR}" ]; then
    ${EDITOR} ${syslinuxCfgFile}
fi

unmount_dir ${rootMount}
}

syslinux_menu () {
# check if already installed
installedForBIOS='idk'
if [ -n "${installDisk}" ]; then
    # MBR is the first 512 bytes in MBR disks. need to grep --text, as output of dd is binary
    syslinuxMbrSum=$(sha1sum -b /usr/lib/syslinux/bios/gptmbr.bin)
    installedMbrSum=$(dd if=${installDisk} bs=440 count=1 2>/dev/null | sha1sum -b)
    if [ "${syslinuxMbrSum% *}" = "${installedMbrSum% *}" ]; then
        installedForBIOS='YES'
    else
        installedForBIOS='NO'
    fi
fi
installedForUEFI='idk'
if [ -n "${ESP}" ]; then
    mount_part ${ESP} ${ESPMount}
    bootEfiApp="${ESPMount}/EFI/BOOT/BOOTX64.EFI"
    if [ -e "${bootEfiApp}" ] && [ -n "$(cat "${bootEfiApp}" | grep 'GRUB')" ]; then
        installedForUEFI='YES'
    else
        installedForUEFI='NO'
    fi
    unmount_dir ${ESPMount}
fi
configFileExists='idk'
if [ -e "${rootPart}" ]; then
    mount_part ${rootPart} ${rootMount}
    if [ -e "${syslinuxCfgFile}" ]; then
        configFileExists='YES'
    else
        configFileExists='NO'
    fi
    unmount_dir ${rootMount}
fi

# SYSLINUX dialog
${dialog} --text="SYSLINUX

chosen install disk: ${installDisk}
chosen data partition: ${rootPart}
chosen EFI System Partition: ${ESP}

installed for BIOS on ${installDisk}: ${installedForBIOS}
installed for UEFI on ${ESP}: ${installedForUEFI}
config file exists at ${syslinuxCfgFile}: ${configFileExists}" \
--button={'install for BIOS:2','install for UEFI:3','configure SYSLINUX:4'} ${dhome}
case ${?} in
2)
    syslinux_bios_inst
    ;;
3)
    syslinux_uefi_inst
    ;;
4)
    syslinux_cfg
    ;;
${dhomecode})
    return
    ;;
esac

syslinux_menu
}

menu () {
retChoices=$(${dialog} --text-align="CENTER" \
--text="welcome!\nyou are expected to have read the alphaOS readmes at Right-click -> Readme. that's about it :)\n" \
--form --align=right \
--field="install to disk:CB" "$(get_disks)" \
--field="copy alphaOS files to partition:CB" "$(get_partitions)" \
--field="(EFI System Partition):CB" "$(get_ESPs)" \
--button={"clean and format disk:2","copy alphaOS files:3","set up boot loader:4"} \
${dquit})

retVal=${?}

# process choices
# if the dialog had no choice, '(null)' is returned. we substitute that with ''
retChoices=$(echo "${retChoices}" | sed 's/(null)//g')
installDisk=$(echo "${retChoices}" | cut -d '|' -f 1 | cut -d ' ' -f 1)
rootPart=$(echo "${retChoices}" | cut -d '|' -f 2 | cut -d ' ' -f 1)
ESP=$(echo "${retChoices}" | cut -d '|' -f 3 | cut -d ' ' -f 1)

case ${retVal} in
2)
    prepare_disk
    ;;
3)
    alpha_inst
    ;;
4)
    syslinux_menu
    ;;
${dquitcode})
    exit 0
    ;;
esac

menu
}
# -------------------------------
# ---------- Functions ----------
# -------------------------------

# -------------------------------
# ---------- Execution ----------
# -------------------------------

# are we root?
priv_check

# ensure dependencies are met
dep_ensure

# show menu
menu

# -------------------------------
# ---------- Execution ----------
# -------------------------------
