#!/bin/bash
#
# script to set up the ccs environment: user ccs, group, sudoers, directories
#
#------------------------------------------------------------------------------

set -e

shost=${HOSTNAME%%.*}

## Slow. Maybe better done separately?
yum group list installed | grep -qi "GNOME Desktop" || {
    echo "Installing gnome"
    yum -q -y groups install "GNOME Desktop"
}

for f in git emacs; do
    rpm --quiet -q $f || yum -q -y install $f
done

#- to run this on a fresh machine you need to copy locally as in:
#  scp lsst-ss01:/gpfs/slac/lsst/fs2/u1/ir2admin/SetUpCCS.sh /tmp
#  sudo /tmp/SetUpCCS.sh
#  or it will be in:
#         /lnfs/lsst/ir2admin/SetUpCCS.sh, just run from there
#  or clone from https://github.com/lsst-camera-dh/ccs-infrastructure

#------------------------------------------------------------------------------
#-- group and user for ccs
#
grep -q "^ccs:x:23000" /etc/passwd || \
    /usr/sbin/adduser -c "CCS Operator Account" --groups dialout \
                      --create-home --uid 23000 ccs

#------------------------------------------------------------------------------
#-- location for ccs software
#
for d in /opt/lsst/ccs /opt/lsst/ccsadm; do
    [ -d $d ] || mkdir -p $d
    stat -c %u:%g $d | grep -q "23000:23000" || chown ccs.ccs $d
done

#-- /lsst link management
[ -h /lsst ] || ln -s /opt/lsst /lsst

for d in release dev-package-lists; do
    d=/lsst/$d
    [ -d $d ] && mv $d /lsst/ccsadm/
done

#-- log area, etc/ccs
for d in /var/log/ccs /etc/ccs; do
    [ -d $d ] || mkdir -p $d
    stat -c %u:%g $d | grep -q "0:23000" && continue
    chown root.ccs $d
    chmod g+s $d
    case $d in
        /var/log/ccs) chmod a+rw $d ;;
        /etc/ccs) chmod g+rw $d ;;
    esac
done

#-- etc/ccs/ccsGlobal.properties file management
f=/etc/ccs/ccsGlobal.properties
[ -e $f ] || touch $f
grep -q "^org.lsst.ccs.level=INFO" $f || echo "org.lsst.ccs.level=INFO" >> $f
grep -q "^org.lsst.ccs.logdir=/var/log/ccs" $f || \
    echo "org.lsst.ccs.logdir=/var/log/ccs" >> $f
#-- etc/ccs/ccsGlobal.properties file management
f=/etc/ccs/udp_ccs.properties
[ -e $f ] || touch $f
grep -q "^org.lsst.ccs.jgroups.ALL.UDP.bind_addr=$(hostname --fqdn)" $f || \
    echo "org.lsst.ccs.jgroups.ALL.UDP.bind_addr=$(hostname --fqdn)" >> $f


#------------------------------------------------------------------------------
#- add the dh account
grep -q "23001" /etc/passwd || \
    /usr/sbin/adduser -c "LSST Data Handling Account" \
                      --groups dialout --create-home --uid 23001 dh

#------------------------------------------------------------------------------
#- add and manage the lsstadm group
grep -q "^lsstadm:x:24000" /etc/group || groupadd --gid 24000 lsstadm
grep -q "^lsstadm:x:24000.*ccs" /etc/group || \
    gpasswd --add ccs lsstadm >/dev/null
grep -q "^lsstadm:x:24000.*dh" /etc/group || \
    gpasswd --add dh lsstadm >/dev/null

#------------------------------------------------------------------------------
#-- sudoers configuration
#-- allows members of lsst-ccs unix group to run any command (and shell) as
#   the "ccs" user
f=/etc/sudoers.d/group-lsst-ccs
[ -e $f ] || touch $f

grep -q "^%lsst-ccs ALL = (ccs) ALL" $f || \
    echo "%lsst-ccs ALL = (ccs) ALL" >> $f
grep -q "^%lsst-ccs ALL = (dh) ALL" $f || \
    echo "%lsst-ccs ALL = (dh) ALL" >> $f

sudoers="gmorris marshall tonyj turri"
for u in $sudoers; do
    f=/etc/sudoers.d/user-$u
    [ -e $f ] && continue
    echo "$u   ALL=ALL" > $f
done

#------------------------------------------------------------------------------

#- get nfs set up
#- need nfs programs
rpm --quiet -q nfs-utils || yum -d1 -y install nfs-utils

#- get rid of old /lnfs/lsst mount point if in use and entry in fstab
mount | grep -q lnfs && umount /lnfs/lsst
[ ! -L /lnfs/lsst ] && [ -d /lnfs/lsst ] && rmdir /lnfs/lsst
grep -q "/lnfs/lsst" /etc/fstab && sed -i -e '/\/lnfs\/lsst/d' /etc/fstab


### Mount the fs[123] gpfs file systems via NFS, if needed.

native_gpfs=
grep -q "^lsst-fs[123].*gpfs" /etc/fstab && native_gpfs=t

[ "$native_gpfs" ] || {

    auto_gpfs=/etc/auto.gpfs

    [ -e $auto_gpfs ] || cat <<EOF > $auto_gpfs
#
# This is an automounter map and it has the following format
# key [ -mount-options-separated-by-comma ] location
# Details may be found in the autofs(5) manpage

EOF

    ## It would be nicer to only use eg "fs1" (rather than "fs1/g"),
    ## but it seems as if the server is not set up to allow that.
    ## (Maybe this is an nfs3 issue?)
    for f in fs1/g fs2/u1 fs3/g; do

        h=lsst-ss01

        case $f in
            fs3*) h=lsst-ss02 ;;    # note different host for this one
        esac

        f=/gpfs/slac/lsst/$f

        mount | grep -q $f && umount $f

        mkdir -p ${f%/*}

        grep -q "^$f" $auto_gpfs && continue

        printf "%-30s %s\n" "$f" "$h.slac.stanford.edu:&" >> $auto_gpfs

    done


    gpfs_autofs=/etc/auto.master.d/gpfs.autofs

    [ -e $gpfs_autofs ] || touch $gpfs_autofs

    ## NB need vers=3 to avoid problems with (bonded) wifi.
    case $shost in
        *-aio*) opt="  vers=3" ;;
        *) opt= ;;
    esac

    grep -q $auto_gpfs $gpfs_autofs || \
        echo "/-	${auto_gpfs}${opt}" >> $gpfs_autofs


    ## Remove "sss" so as to avoid a bunch of SLAC NFS that we don't want.
    ## FIXME "Generated by Chef. Local modifications will be overwritten."
    sed -i.ORIG 's/^automount:.*/automount:	files/' /etc/nsswitch.conf


    systemctl -q is-enabled autofs || systemctl enable autofs
    ## TODO only if necessary, ie if not running or we changed something.
    systemctl restart autofs

}                               # native_gpfs


#- fix up so old /lnfs path still works
[ -d /lnfs ] || mkdir /lnfs
[ -L /lnfs/lsst ] || ln -s /gpfs/slac/lsst/fs2/u1 /lnfs/lsst


#------------------------------------------------------------------------------
#- dh software is in NFS
[ -h /lsst/dh ] || ln -s /lnfs/lsst/dh /lsst/dh
[ -h /lsst/data ] || ln -s /lnfs/lsst/data /lsst/data

#------------------------------------------------------------------------------
#- install the correct java from nfs
jdkrpm=/lnfs/lsst/pkgarchive/jdk-8u112-linux-x64.rpm
javaver=$(rpm -qi -p ${jdkrpm} | gawk '/^Version/ {print $3}';)
javapkg=$(rpm -q -p ${jdkrpm})
rpm --quiet -q ${javapkg} || rpm -i ${jdkrpm}
java -version 2>&1 | grep -q -F ${javaver} || {
   for cmd in java javac javaws jar jconsole ; do
      update-alternatives --install /usr/bin/${cmd} ${cmd} \
                          /usr/java/jdk${javaver}/bin/${cmd} 1000
      update-alternatives --set ${cmd} /usr/java/jdk${javaver}/bin/${cmd}
   done
}
#------------------------------------------------------------------------------
#- gdm and graphical stuff on workstations

## FIXME restrict by hostname.
rpm --quiet -q gdm && {
    systemctl enable gdm
    systemctl set-default graphical.target
    yum -d1 -y remove gnome-initial-setup
}
#------------------------------------------------------------------------------
#- selinux
setenforce 0
grep -q "SELINUX=enforcing" /etc/selinux/config && \
    sed -i.ORIG -e 's/=enforcing/=permissive/' /etc/selinux/config
#------------------------------------------------------------------------------
#- firewalld
rpm --quiet -q firewalld && {
    systemctl status firewalld | grep -q 'Loaded: masked' || \
        systemctl mask --now firewalld
}
#------------------------------------------------------------------------------
#- ccs update-k5login
[ -d ~ccs/crontabs ] || mkdir ~ccs/crontabs

f=~ccs/crontabs/update-k5login
if [ ! -e $f ] || [ ! -x $f ] ; then
   cat <<EOF >>$f
#!/bin/bash
getent netgroup u-lsst-ccs |
 sed -e 's/(-,//g' |\
 sed -e 's/,)//g' |\
 sed -e 's/^u-lsst-ccs *//' |\
 tr ' ' '\n' |\
 sed -e 's/$/@SLAC.STANFORD.EDU/' > /tmp/.k5login
rsync --checksum /tmp/.k5login ~

EOF
   chown -R ccs:ccs ~ccs/crontabs
fi
[ -x $f ] || chmod +x $f
#- run update-k5login
sudo -u ccs $f
#- update the crontab file if needed
crontab -u ccs -l | grep -q update-k5login ||\
echo "0,15,30,45 * * * * $f" | crontab -u ccs -
#------------------------------------------------------------------------------
#

## Files required for CCS software.
## https://jira.slac.stanford.edu/browse/LSSTIR-40

rpm --quiet -q rsync || yum -d1 -y install rsync

ccs_scripts=~ccs/scripts
ccs_scripts_src=lsst-mcm:scripts

[ -e $ccs_scripts/installCCS.sh ] || {

    rsync -aSH ccs@$ccs_scripts_src/ $ccs_scripts/
    chown -R ccs:ccs $ccs_scripts
}


ccsadm=/opt/lsst/ccsadm             # created above

github=https://github.com/lsst-camera-dh

rpm --quiet -q git || yum -d1 -y install git

[ -e $ccsadm/release ] || \
    su ccs -c "cd $ccsadm && git clone $github/release.git"

[ -e $ccsadm/dev-package-lists ] || \
    su ccs -c "cd $ccsadm && git clone $github/dev-package-lists.git"

## To actually install it:
## (Needs the host to be registered somewhere, else does nothing?)
###su ccs -c "~ccs/scripts/installCCS.sh IR2 console"


## Environment variables etc.
f=/etc/profile.d/lsst-ccs.sh

[ -e $f ] || touch $f

## https://lsstc.slack.com/archives/CCQBHNS0K/p1553877151009500
grep -q "OMP_NUM_THREADS" $f || \
    cat <<EOF >> $f
# Stop python OpenBLAS running amok.
export OMP_NUM_THREADS=1
EOF


## EPEL
yum -d1 -y install x2goclient x2goserver x2godesktopsharing


## grub
## https://github.com/sriemer/fix-linux-mouse/
## Prevent console spam from some common dell usb mice.
f=/etc/default/grub
grep -q usbhid.quirks $f || \
    sed -i.ORIG -e '/^GRUB_CMDLINE_LINUX=/ s/"$/ usbhid.quirks=0x413c:0x301a:0x00000400,0x04ca:0x0061:0x00000400"/' \
    $f

grubfile=/boot/efi/EFI/centos/grub.cfg

[ -e $grubfile ] || grubfile=/boot/grub2/grub.cfg

grub2-mkconfig -o $grubfile


## ssh
[ -d /root/.ssh ] || mkdir -m 700 /root/.ssh

## chef creates this as a symlink to .public/authorized_keys,
## presumably for afs.
f=/root/.ssh/authorized_keys

[ -e $f ] || ( umask 077 && touch $f )

## This allows logins from hosts with the associated private key.
grep -q "root@lsst-ss01" $f || cat >> $f <<EOF
#
# GPFS cluster name: lsst-ss01.slac.stanford.edu
from="*.slac.stanford.edu" ssh-dss AAAAB3NzaC1kc3MAAACBAJVRTAdjoR/1Sir4/caVnv5uIIYpzJvZn8U2yUWa15mNhJlKNH+x0ZBCr5YtqHCkYDWq1lk42eLUgoQn0rhJTbp4AvOO6FCrP61cMyYgJgpfv56InBvhF7aWFwhJsPAym4cQC1/7znmQfR8iM6dxA8z2yThwpUdRAXT4s4c16y0bAAAAFQDuy9XdUIOYTf0Cx4+cP5tZuTWyzQAAAIBjkkDeIAI44VdwTFzubnj5oLU9oXYahibPkTHKyFGVfp330s5+AnOFITXFULPiqCzM0/QiVqZjbWdwDClMIW4OzVbAs4zZ38bpbA08FfCXQ9t9Q2jp6sdI0iDX+ZgBkU1KuDl8uFYV+P0WPiG6nQ90+uo9FRtEuCZNehnKPMJFqgAAAIAoRslF1H+MLA471jndzHIkIGPA8bqKsGSgjSEFEsR1yTnqyVQf2PwrjtIv2PrARNaP76ekeYcYF4+Ql+88hcvfFMUejc4IUTJDQ7U8XL08CzkiG2hZfR5jXlxNoSHpISUE1eEBhYeks4HJV8JjjMyap5ccUoh40N9ezePKdrSjSQ== root@lsst-ss01.slac.stanford.edu

EOF

## FIXME this won't work because until we get this key we cannot login
## to other hosts. Need a common file-system (eg nfs).
rsync -aX lsst-mcm:.ssh/id_dsa .ssh/ || \
    echo "Failed to copy /root/.ssh/id_dsa - push from another host"

rsync -aX lsst-mcm:/etc/ssh/ssh_known_hosts /etc/ssh/ || \
    echo "Failed to copy /etc/ssh/ssh_known_hosts - push from another host"


### Host-specific stuff.

[ $shost = lsst-ir2daq01 ] && {
    ## FIXME interface name may vary - discover/check it?
    f=/etc/NetworkManager/dispatcher.d/30-ethtool
    [ -e $f ] || cat <<'EOF' > $f
#!/bin/sh

# https://access.redhat.com/solutions/2841131

myname=${0##*/}
log() { logger -p user.info -t "${myname}" "$*"; }
IFACE=$1
ACTION=$2

log "IFACE = $1, ACTION = $2"

if [ "$IFACE" == "p3p1" ] && [ "$ACTION" == "up" ]; then
    log "ethool set-ring ${IFACE} rx 4096 tx 4096"
    /sbin/ethtool --set-ring ${IFACE} rx 4096 tx 4096
    log "ethool pause ${IFACE} autoneg off rx off tx off"
    /sbin/ethtool --pause ${IFACE} autoneg off rx off tx off
fi

exit 0
EOF

}                               # ir2daq01
