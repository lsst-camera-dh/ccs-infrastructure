#!/bin/bash
#
# script to set up the ccs environment: user ccs, group, sudoers, directories
#
#------------------------------------------------------------------------------
# To run this script on a fresh machine, first get a local copy.
# The best method is to use:
# git clone https://github.com/lsst-camera-dh/ccs-infrastructure
# Or (but these may not be as up-to-date as the above version):
#  scp lsst-ss01:/gpfs/slac/lsst/fs2/u1/ir2admin/SetUpCCS.sh /tmp
#  sudo /tmp/SetUpCCS.sh
#  or run directly from /lnfs/lsst/ir2admin/SetUpCCS.sh

set -e

shost=${HOSTNAME%%.*}

my_system=

while read ip; do
    case $ip in
        134.79.*) my_system=slac ;;
        140.252.*|10.0.103.*) my_system=tucson ;;
        139.229.174.*) my_system=chile ;;
    esac
    [ "$my_system" ] && break
done < <(hostname -I)

if [ "$my_system" ]; then
    echo "my_system = $my_system"
else
    echo "Unable to identify network"
    exit 1
fi

case $my_system in
    slac)
        timedatectl | grep -q "RTC in local TZ: yes" && {
            echo "Setting RTC to UTC"
            timedatectl set-local-rtc 0
            /usr/sbin/hwclock -w # should not be needed, but is?
        }

        ## Slow. Maybe better done separately?
        ## FIXME. Also don't want this on servers.
        ## Although people sometimes want to eg use vnc,
        ## so it does end up being needed on servers too.
        ## "Server with GUI" instead? Not much smaller.
        yum group list installed | grep -qi "GNOME Desktop" || {
            echo "Installing gnome"
            yum -q -y groups install "GNOME Desktop"
            yum clean all
        }
        ;;

    tucson|chile)
        timedatectl | grep -q "Time zone: UTC" || {
            echo "Setting TZ to UTC"
            ## TODO this may leave the time wrong by several hours?
            timedatectl set-timezone UTC
        }
        ;;
esac


# TODO: maven is only needed on "development" machines,
# but exactly what these are is not yet defined.
for f in epel-release git rsync emacs chrony nano ntp screen sysstat unzip \
      kernel-headers kernel-devel clustershell maven monit freeipmi \
      attr parallel gcc devtoolset-8 dkms usbutils; do
    rpm --quiet -q $f || yum -q -y install $f
done

case $shost in
    lsst-it01|*-aio*|*-vw*) yum -q -y install libreoffice-base ;;
esac

# It's hard to construct this automatically.
rpm --quiet -q clustershell && \
    echo "REMEMBER to customize /etc/clustershell/groups.d/local.cfg"

## Ultimately ptp will replace this.
case $my_system in
    slac) systemctl disable chronyd ;; # slac uses ntpd
    ## TODO: make sure clock is approximately correct first?
    ## FIXME tucson was using chrony originally, then switched some
    ## hosts to ntp.
    tucson-OFF)
        ## Puppet-installed hosts at Tucson seem to use (unconfigured)
        ## chrony, but hand-installed ones use (configured) ntp.
        ## For consistency, use ntp.
        ## TODO: Disabled for now so as not to mess with puppet...
        systemctl disable chronyd
        systemctl enable ntpd

        if grep -q "^server 140" /etc/ntp.conf; then
            systemctl -q is-active ntpd || systemctl start ntpd
        else
            cat <<EOF >> /etc/ntp.conf
server 140.252.1.140 iburst
server 140.252.1.141 iburst
server 140.252.1.142 iburst
server 140.252.32.45   # added by /sbin/dhclient-script
EOF
            systemctl restart ntpd
        fi
        ;;
esac

### 2019/10/09: changed to dedicated user account, managed by puppet.
### See https://jira.lsstcorp.org/browse/IHS-2831
## For this to work, the host IP needs to be whitelisted by Tucson IHS.
## Check for rejections in journalctl -u postfix
### [ $my_system = tucson ] && ! grep -q "^relayhost" /etc/postfix/main.cf && {
###         cp -a /etc/postfix/main.cf /etc/postfix/main.cf.ORIG
###         echo "relayhost = mail.lsst.org" >> /etc/postfix/main.cf
###         systemctl restart postfix
### }


#------------------------------------------------------------------------------
#-- group and user for ccs
#
## NB if you are adding more users to the system by hand, the next one
## will get a uid in the 23000 range if you don't do anything,
## eg use useradd -K UID_MAX=22000.
## TODO: should this be a system (uid < 1000) account?
## Or should it be greater than UID_MAX (default 60000)?
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


## TODO what should the ownership of these files be?
## https://jira.slac.stanford.edu/browse/LSSTIR-43

for f in ccsGlobal.properties logging.properties; do
    f=/etc/ccs/$f
    [ -e $f ] || cp ./ccs/${f##*/} $f
done

f=/etc/ccs/udp_ccs.properties
[ -e $f ] || {
    ## FIXME If the system does not have an fqdn (tucson), we should use
    ## the IP address here. But that is less portable if the system gets a
    ## new IP.
    HOSTNAME=$(hostname --fqdn)
    sed "s/HOSTNAME/${HOSTNAME}/" ./ccs/${f##*/}.template > $f
done


#- add the dh account
# This is for etraveler, only used at slac.
[ $my_system = slac ] && {
    grep -q "23001" /etc/passwd || \
        /usr/sbin/adduser -c "LSST Data Handling Account" \
                          --groups dialout --create-home --uid 23001 dh
}


#------------------------------------------------------------------------------
#- add and manage the lsstadm group
grep -q "^lsstadm:x:24000" /etc/group || groupadd --gid 24000 lsstadm
grep -q "^lsstadm:x:24000.*ccs" /etc/group || \
    gpasswd --add ccs lsstadm >/dev/null

grep -q "^dh:" /etc/passwd && \
    ! grep -q "^lsstadm:x:24000.*dh" /etc/group && \
    gpasswd --add dh lsstadm >/dev/null


### Sudoers.

## Allow members of lsst-ccs unix group to run any command as the "ccs" user.
## At SLAC, this group is managed centrally by a netgroup.
## TODO the Tucson policy is not yet defined.
f=/etc/sudoers.d/group-lsst-ccs
[ -e $f ] || touch $f

sudo_opt="%lsst-ccs ALL = (ccs) ALL"
[ $my_system = tucson ] && sudo_opt="${sudo_opt%ALL}NOPASSWD: ALL"

grep -q "^$sudo_opt" $f || echo "$sudo_opt" >> $f

grep -q "^dh:" /etc/passwd && {
    sudo_opt="${sudo_opt/(ccs)/(dh)}"
    grep -q "^$sudo_opt" $f || echo "$sudo_opt" >> $f
}

[ $my_system = slac ] && {

    sudoers="gmorris marshall tonyj turri"
    for u in $sudoers; do
        f=/etc/sudoers.d/user-$u
        [ -e $f ] && continue
        echo "$u   ALL=ALL" > $f
    done
}                               # my_system = slac


### NFS.

rpm --quiet -q nfs-utils || yum -q -y install nfs-utils
rpm --quiet -q autofs || yum -q -y install autofs

#- get rid of old /lnfs/lsst mount point if in use and entry in fstab
[ $my_system = slac ] && {

    mount | grep -q lnfs && umount /lnfs/lsst
    [ ! -L /lnfs/lsst ] && [ -d /lnfs/lsst ] && rmdir /lnfs/lsst
    grep -q "/lnfs/lsst" /etc/fstab && sed -i -e '/\/lnfs\/lsst/d' /etc/fstab
}


### Mount the fs[123] gpfs file systems via NFS, if needed.
[ $my_system = slac ] && {

    native_gpfs=
    grep -q "^lsst-fs[123].*gpfs" /etc/fstab && native_gpfs=t

    [ "$native_gpfs" ] || {

        ## Not strictly necessary since nfs paths are also pruned,
        ## but this may avoid some hangs when the server does not respond.
        grep -q "PRUNEPATHS.*/gpfs " /etc/updatedb.conf || \
            sed -i.ORIG 's|^\(PRUNEPATHS = "\)|\1/gpfs |' /etc/updatedb.conf

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
            ## Some hosts need vers=4.0 (to avoid lsst-ss01 hangs)?
            ## Some older autofs will reject the ".", so use "vers=4".
            ## https://bugzilla.redhat.com/show_bug.cgi?id=1486035
            *) opt= ;;
        esac

        ## 201916: Avoid Ganesha nfsv4 lease bug. SLAC INC0239891.
        opt="  vers=3"

        grep -q $auto_gpfs $gpfs_autofs || \
            echo "/-	${auto_gpfs}${opt}" >> $gpfs_autofs


        ## Remove "sss" so as to avoid a bunch of SLAC NFS that we don't want.
        ## FIXME "Generated by Chef. Local modifications will be overwritten."
        sed -i.ORIG 's/^automount:.*/automount:	files/' /etc/nsswitch.conf


        systemctl -q is-enabled autofs || systemctl enable autofs
        ## TODO only if necessary, ie if not running or we changed something.
        systemctl restart autofs

    }                           # native_gpfs

    #- fix up so old /lnfs path still works
    [ -d /lnfs ] || mkdir /lnfs
    [ -L /lnfs/lsst ] || ln -s /gpfs/slac/lsst/fs2/u1 /lnfs/lsst

    #- dh software is in NFS
    [ -h /lsst/dh ] || ln -s /lnfs/lsst/dh /lsst/dh
    [ -h /lsst/data ] || ln -s /lnfs/lsst/data /lsst/data
}                               # my_system = slac


#------------------------------------------------------------------------------
#- install the correct java from nfs

if [ $my_system = slac ]; then
    jdkrpm=/lnfs/lsst/pkgarchive/jdk-8u112-linux-x64.rpm
else
    ## FIXME
    jdkrpm=/root/jdk-8u112-linux-x64.rpm
fi

if [ -e $jdkrpm ]; then

    javaver=$(rpm -qi -p ${jdkrpm} | gawk '/^Version/ {print $3}';)
    javapkg=$(rpm -q -p ${jdkrpm})
    rpm --quiet -q ${javapkg} || rpm -i ${jdkrpm} > /dev/null
    java -version 2>&1 | grep -q -F ${javaver} || {
        for cmd in java javac javaws jar jconsole jstack; do
            update-alternatives --install /usr/bin/${cmd} ${cmd} \
                                /usr/java/jdk${javaver}/bin/${cmd} 1000
            update-alternatives --set ${cmd} /usr/java/jdk${javaver}/bin/${cmd}
        done
    }
else
    echo "WARNING skipping missing jdkrpm: $jdkrpm"
fi

#------------------------------------------------------------------------------
#- gdm and graphical stuff on workstations

## FIXME restrict by hostname.
## FIXME this test is wrong for servers if we have installed the
## graphical stuff.
rpm --quiet -q gdm && {
    systemctl enable gdm
    systemctl get-default | grep -qF graphical.target || \
        systemctl set-default graphical.target
    rpm --quiet -q gnome-initial-setup && \
        yum -q -y remove gnome-initial-setup
}

systemctl disable initial-setup-graphical initial-setup-text


getenforce 2> /dev/null | grep -qi Enforcing && setenforce 0
grep -q "SELINUX=enforcing" /etc/selinux/config && \
    sed -i.ORIG -e 's/=enforcing/=permissive/' /etc/selinux/config


rpm --quiet -q firewalld || yum -q -y install firewalld

systemctl status firewalld | grep -q 'Loaded: masked' || \
    systemctl mask --now firewalld


rpm --quiet -q fail2ban || yum -q -y install fail2ban

## For now, disable.
systemctl status fail2ban | grep -q 'Loaded: masked' || \
    systemctl mask --now fail2ban


[ $my_system = slac ] && {

    ## Allow all SLAC traffic.
    ## Note that public hosts should also allow ssh from anywhere.
    ## TODO we might want to be more restrictive, eg 134.79.209.0/24.
    ## TODO what about things like DAQ, PTP etc on private subnets?
    f=/etc/firewalld/zones/trusted.xml
    [ -e $f ] || cat <<'EOF' > $f
<?xml version="1.0" encoding="utf-8"?>
<zone target="ACCEPT">
  <short>Trusted</short>
  <description>All network connections are accepted.</description>
  <source address="134.79.0.0/16"/>
</zone>
EOF

    ## Whitelist all SLAC ips.
    f=/etc/fail2ban/jail.d/10-lsst-ccs.conf
    [ -e $f ] || cat <<'EOF' > $f
[DEFAULT]
ignoreip = 127.0.0.1/8 134.79.0.0/16

# 1w.
bantime = 604800

# maxretry failures in findtime seconds.
findtime  = 3600

maxretry = 10

[sshd]

enabled = true
EOF

## SLAC logs to /var/log/everything instead of /var/log/secure.
    f=/etc/fail2ban/paths-overrides.local
    [ -e /var/log/everything ] && [ ! -e $f ] && cat <<'EOF' > $f
[DEFAULT]

syslog_authpriv = /var/log/everything

syslog_user =  /var/log/everything

syslog_ftp  = /var/log/everything

syslog_daemon  = /var/log/everything

syslog_local0  = /var/log/everything

EOF

}                               # my_system = slac


#------------------------------------------------------------------------------
#- ccs update-k5login

[ $my_system = slac ] && {

    [ -d ~ccs/crontabs ] || mkdir ~ccs/crontabs

    f=~ccs/crontabs/update-k5login
    if [ ! -e $f ] || [ ! -x $f ] ; then
        cp ./update-k5login $f
        chown -R ccs:ccs ~ccs/crontabs
fi
    [ -x $f ] || chmod +x $f
    #- run update-k5login
    sudo -u ccs $f
    #- update the crontab file if needed
    crontab -u ccs -l >& /dev/null | grep -q update-k5login || \
        echo "0,15,30,45 * * * * $f" | crontab -u ccs -
}                               # my_system = slac

## Files required for CCS software.
## https://jira.slac.stanford.edu/browse/LSSTIR-40

ccs_scripts=~ccs/scripts
#ccs_scripts_src=lsst-mcm:scripts
## Now added to the repository with this script.
ccs_scripts_src=install

## NB prevent prompts about host keys.
export RSYNC_RSH="ssh -o StrictHostKeyChecking=no -oBatchMode=yes"

[ -e $ccs_scripts/installCCS.sh ] || {

#    rsync -aSH ccs@$ccs_scripts_src/ $ccs_scripts/
    rsync -aSH $ccs_scripts_src/ $ccs_scripts/
    chown -R ccs:ccs $ccs_scripts
}


ccsadm=/opt/lsst/ccsadm             # created above

github=https://github.com/lsst-camera-dh

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

# Add to start.
grep -q 'UID -gt 1000' $f || {
    cat - $f <<'EOF' >| $f.temp
[ $UID -ge 1000 ] || return
EOF
    mv -f $f.temp $f
}

## https://lsstc.slack.com/archives/CCQBHNS0K/p1553877151009500
grep -q "OMP_NUM_THREADS" $f || cat <<EOF >> $f

# Stop python OpenBLAS running amok.
export OMP_NUM_THREADS=1
EOF

grep -q '/lsst/ccs/prod/bin' $f || cat <<'EOF' >> $f

# Add /lsst/ccs/prod/bin to PATH if not present.
_dir=/lsst/ccs/prod/bin
[ -e $dir ] && [[ $PATH != *$_dir* ]] && PATH=$_dir:$PATH
EOF


## Make permissions like /tmp.
## TODO improve partitioning scheme.
[ -d /scratch ] && grep -q "/scratch " /etc/mtab && chmod 1777 /scratch


## TODO this should be part of the user creation step.
## I believe changing UMASK in /etc/login.defs would change the default
## for home creation (and nothing else?).
## Seems like all users should be in the same group though, rather
## than each having their own.
[ $my_system = tucson ] && chmod 755 /home/*


## Applications menu.

f=/etc/xdg/menus/applications-merged/lsst.menu
mkdir -p ${f%/*}
[ -e $f ] || cat <<'EOF' > $f
<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
"http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
<Menu>
<Name>Applications</Name>
<Menu>
<Name>LSST</Name>
<Directory>lsst.directory</Directory>
<Include>
<Category>LSST</Category>
</Include>
</Menu>
</Menu>
EOF

f=/usr/share/desktop-directories/lsst.directory
mkdir -p ${f%/*}
[ -e $f ] || cat <<'EOF' > $f
[Desktop Entry]
Type=Directory
Name=LSST
Icon=lsst_appicon
EOF

d=/usr/share/applications
mkdir -p $d
for f in console.{prod,dev} shell.{prod,dev}; do

    t=${f#*.}                   # prod or dev

    app=${f%.*}                 # console or shell

    f=lsst.ccs.$f.desktop

    [ -e $d/$f ] && continue

    case $t in
        prod) ver="production" ;;
        dev) ver="development" ;;
    esac

    case $app in
        console) terminal=false ;;
        shell) terminal=true ;;
    esac

    cat <<EOF > $d/$f
[Desktop Entry]
Type=Application
Encoding=UTF-8
Name=CCS $app ($t)
Comment=Camera Control System $app ($ver version)
Exec=/lsst/ccs/$t/bin/ccs-$app
Categories=LSST;
Terminal=$terminal
Icon=lsst_appicon
EOF
done


## FIXME not a great icon.
f=/usr/share/icons/lsst_appicon.png
mkdir -p ${f%/*}
[ -e $f ] || cp ./lsst_appicon.png $f


## EPEL
## FIXME graphical hosts only.
rpm --quiet -q gdm && {
    ## This seems to be the smallest WM one can install.
    rpm -q --quiet icewm || yum -q -y install icewm || true
    rpm -q --quiet x2goclient || \
        yum -q -y install x2goclient x2goserver x2godesktopsharing || true
}


## cron
## We assume that you ran this script via ./ from a git checkout
## of the script repository.
cp -a ./ccs-sudoers-services /etc/cron.hourly/ || true


## grub
## https://github.com/sriemer/fix-linux-mouse/
## Prevent console spam from some common dell usb mice.
[ $my_system = slac ] && {

    f=/etc/default/grub
    grub_ok=t
    grep -q usbhid.quirks $f || {
        grub_ok=
        sed -i.ORIG -e '/^GRUB_CMDLINE_LINUX=/ s/"$/ usbhid.quirks=0x413c:0x301a:0x00000400,0x04ca:0x0061:0x00000400"/' \
            $f
    }

    grubfile=/boot/efi/EFI/centos/grub.cfg

    if [ -e $grubfile ]; then
        efiflag=t
    else
        efiflag=
        grubfile=/boot/grub2/grub.cfg
    fi

    [ "$grub_ok" ] || grub2-mkconfig -o $grubfile
}                               # my_system = slac


## ssh
[ $my_system = slac ] && {
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

    ## Chef manages /etc/ssh/ssh_known_hosts
    rsync -aX lsst-mcm:/etc/ssh/ssh_known_hosts_local /etc/ssh/ || \
        echo "Failed to copy /etc/ssh/ssh_known_hosts_local - push from another host"
}                               # my_system = slac


### Monit.

## TODO separate script for all this, using template files?

mkdir -p /var/monit             # not sure if program creates this...

## Change check interval from 30s to 5m.
## TODO? add "read-only" to the allow line?
sed -i.ORIG 's/^set daemon  30 /set daemon  300 /' /etc/monitrc

monitd=/etc/monit.d

[ -e $monitd/alert ] || {

    ## TODO add another email address in case slack is down.
    case $my_system in
        slac)
            mailhost=smtpunix.slac.stanford.edu
            ## cam-ir2-computing-alerts
            monit_addr=k2p7u7n6e7u4r2r7@lsstc.slack.com
            ;;
        tucson)
            mailhost=mail.lsst.org
            ## comcam-alerts
            monit_addr=x7z0x9c0t2k4r1n1@lsstc.slack.com
            ;;
    esac

    cat <<EOF >| $monitd/alert
set mailserver $mailhost,
               localhost
set alert $monit_addr not on { instance, action } reminder 288
EOF

    cat <<'EOF' >> $monitd/alert

set mail-format {
  from:    Monit <monit@$HOST>
  subject: monit alert -- $HOST $SERVICE $EVENT
  message: $EVENT service $SERVICE
                Date:        $DATE
                Host:        $HOST
                Action:      $ACTION
                Description: $DESCRIPTION
}
EOF

}                               # alert


[ -e $monitd/config ] || cat <<'EOF' >| $monitd/config
set pidfile /var/run/monit.pid
set idfile /var/cache/monit.id
set statefile /var/cache/monit.state

set eventqueue
    basedir /var/monit
    slots 100
EOF


function monit_disks () {
    local outfile=$1
    local disk dname

    shift

    for disk; do

        case $disk in
            /) dname=rootfs ;;
            *) dname=${disk//\/} ;;
        esac

        ## Can also do IO rates.
        cat <<EOF >> $outfile
check filesystem $dname with path $disk
     if space usage > 90% then alert
     if inode usage > 90% then alert

EOF
    done
    return 0
}                               # function monit_disks

case $my_system in
    slac)
        ## Ignoring: /boot, and in older installs: /scswork, /usr/vice/cache.
        monit_disks="/ /tmp"
        ## dc nodes have /data.
        ## Older installs have separate /opt /scratch /var.
        ## Newer ones have /home instead.
        monit_disks2="/lsst-ir2db01 /data /home /opt /scratch /var"
        ;;
    tucson)
        ## Could loop over lvm volumes, or /dev/mapper.
        monit_disks="/ /home"
        monit_disks2="/data" # eg fp01, db01
        ;;
esac

[ -e $monitd/disks ] || monit_disks $monitd/disks $monit_disks


[ "$monit_disks2" ] && for disk in $monit_disks2; do

    grep -q "[ 	]$disk[ 	]" /etc/fstab || continue

    monit_disks $monitd/disks-local $disk
done


## Alert if a client loses gpfs.
## TODO add a repeat count here for reboots.
[ "$native_gpfs" ] && [ ! -e $monitd/gpfs-exists ] && \
    cat <<'EOF' > $monitd/gpfs-exists
check file gpfs-fs1-exists with path /gpfs/slac/lsst/fs1/.exists
      if does not exist for 3 cycles then alert

check file gpfs-fs2-exists with path /gpfs/slac/lsst/fs2/.exists
      if does not exist for 3 cycles then alert

check file gpfs-fs3-exists with path /gpfs/slac/lsst/fs3/.exists
      if does not exist for 3 cycles then alert
EOF


[ $shost = lsst-it01 ] && [ ! -e $monitd/gpfs ] && \
    cat <<'EOF' > $monitd/gpfs
check filesystem gpfs-fs1 with path /gpfs/slac/lsst/fs1
     if space usage > 90% then alert
     if inode usage > 90% then alert

check filesystem gpfs-fs2 with path /gpfs/slac/lsst/fs2
     if space usage > 95% then alert
     if inode usage > 95% then alert

check filesystem gpfs-fs3 with path /gpfs/slac/lsst/fs3
     if space usage > 90% then alert
     if inode usage > 90% then alert
EOF


## TODO derive host lists from eg clustershell config?
case $shost in
    lsst-it01)
        ## Excluding lions and unos, which often go up and down.
        monit_ping="lsst-ir2daq01 lsst-ir2db01 lsst-mcm lsst-ss01 lsst-ss02 lsst-vs01 lsst-vw01 lsst-vw02 lsst-dc01 lsst-dc02 lsst-dc03 lsst-dc04 lsst-dc05 lsst-dc06 lsst-dc07 lsst-dc08 lsst-dc09 lsst-dc10"
        monit_ping=$(printf "%s.slac.stanford.edu " $monit_ping)
        ;;
    comcam-fp01)
        monit_ping="comcam-db01 comcam-dc01 comcam-mcm comcam-vw01 comcam-hcu03 comcam-lion01 comcam-lion02 comcam-lion03 pathfinder-lion01"
        ;;
esac


[ "$monit_ping" ] && [ ! -e $monitd/hosts ] && {
    for ping in $monit_ping; do

        cat <<EOF >> $monitd/hosts
check host ${ping%%.*} with address $ping
  if failed ping4 count 3 with timeout 5 seconds then alert

EOF
    done
}                               # hosts


[[ $shost == *-mcm ]] && {
    [ -e $monitd/inlet-temp ] || cat <<'EOF' > $monitd/inlet-temp
check program inlet-temp with path /usr/local/bin/monit_inlet_temp timeout 10 seconds
  if status != 0 then alert
EOF

    cp monit/monit_inlet_temp /usr/local/bin
}


## Note that the use of "per core" requires monit >= 5.26.
## As of 2019/09, the epel7 version is 5.25.1.
## This requires us to install a newer version in /usr/local/bin,
## and modify the service file, but it does mean the config file can
## be identical for all hosts.
## swap warning is not very useful, since Linux doesn't usually free swap.
## Maybe it should just be removed?
[ -e $monitd/system ] || cat <<'EOF' >| $monitd/system
check system $HOST
  if loadavg (1min) per core > 2 for 3 cycles then alert
  if loadavg (5min) per core > 1.5 for 5 cycles then alert
  if cpu usage > 95% for 3 cycles then alert
  if memory usage > 90% for 3 cycles then alert
  if swap usage > 75% for 3 cycles then alert
  if uptime < 15 minutes then alert
EOF
## We are using uptime to detect reboots. It also alerts on success.
## TODO try "else if succeeded exec /usr/bin/true"?


## The "primary" network interface, eg em1 or p4p1.
eth0=$(nmcli -g ip4.address,general.device dev show 2> /dev/null | \
  gawk '/^(134|140|139)/ {getline; print $0; exit}')

[ "$eth0" ] || {
    echo "WARNING: unable to determine primary network interface"
    eth0=em1
}

## TODO try to automatically fix netspeed?
[[ $shost == *-vi* ]] || [ -e $monitd/network ] || cat <<EOF >| $monitd/network
check network $eth0 with interface $eth0
  if changed link capacity then alert
  if saturation > 90% for 3 cycles then alert

check program netspeed with path /usr/local/bin/monit_netspeed timeout 10 seconds
  if status != 0 then alert
EOF

cp monit/monit_netspeed /usr/local/bin


case $shost in
    *-uno*|*-lion*|*-hcu*|*-aio*|*-lt*|*-vw*|*-vi*) : ;;
    *)
        [ -e $monitd/hwraid ] || cat <<'EOF' >| $monitd/hwraid
check program hwraid with path /usr/local/bin/monit_hwraid timeout 10 seconds
  if status != 0 then alert
EOF

        ## Needs the raid utility (eg perccli64) to be installed separately.
        cp monit/monit_hwraid /usr/local/bin
    ;;
esac


[ -e /etc/systemd/system/monit.service ] || \
    sed 's|/usr/bin/monit|/usr/local/bin/monit|g' \
        /usr/lib/systemd/system/monit.service > \
        /etc/systemd/system/monit.service

systemctl -q is-enabled monit || systemctl enable monit

## We can just copy the binary around.
## NB Note that we configure this monit with --prefix=/usr
## so that it consults /etc/monitrc, and install just the binary by
## hand in /usr/local/bin.
echo "TODO: install /usr/local/bin/monit and start service"


### Host-specific stuff.

## Note, in RHEL8 we should be able to use ifcfg- files for this.
## dc01,03,06 (lsst-daq), dc02,ir2daq01 (p3p1)
## TODO Could do this if an "lsst-daq" interface exists.
## Or we could always add the script with an "lsst-daq" name.
case $shost in
    lsst-dc0[1236]|lsst-ir2daq01)

        ## TODO interface name may vary - discover/check it?
        ## Could check for an interface connected to 192.168.100.1,
        ## but unlikely to be specific enough.
        iface=p3p1
        ## Sometimes p3p1 is renamed to lsst-daq.
        /usr/sbin/ip link show lsst-daq >& /dev/null && iface=lsst-daq

        f=/etc/NetworkManager/dispatcher.d/30-ethtool
        [ -e $f ] || cat <<'EOF' > $f
#!/bin/sh

# https://access.redhat.com/solutions/2841131

myname=${0##*/}
log() { logger -p user.info -t "${myname}" "$*"; }
IFACE=$1
ACTION=$2

EOF

        ## Note: asked not to modify DAQ network interfaces.
        echo "DAQ=DISABLED-$iface" >> $f

        cat <<'EOF' >> $f

log "IFACE = $1, ACTION = $2"

if [ "$IFACE" == "$DAQ" ] && [ "$ACTION" == "up" ]; then
    log "ethool set-ring ${IFACE} rx 4096 tx 4096"
    /sbin/ethtool --set-ring ${IFACE} rx 4096 tx 4096
    log "ethool pause ${IFACE} autoneg off rx off tx off"
    /sbin/ethtool --pause ${IFACE} autoneg off rx off tx off
fi

exit 0
EOF
        ;;

    *-vw[0-9][0-9])
        grep -q ^AutomaticLogin /etc/gdm/custom.conf || \
            sed -i.ORIG '/^\[daemon.*/a\
AutomaticLogin=ccs\
AutomaticLoginEnable=true' /etc/gdm/custom.conf
        ;;

    *db[0-9][0-9])
        rpm -q --quiet mariadb-server || yum -q -y install mariadb-server
        systemctl enable --now mariadb
        ## Next:
        ## (Need to decide where to put the db.)
        ## Create empty db called called comcamdbprod;
        ## add ccs account with all privs on that db;
        ## localdb -u to create tables.
        ;;

    *fcs[0-9][0-9]|lsst-lion18)
        ./lion_canbus/setup
        ;;

    ## FIXME what are the right hosts for this?
    lsst-lion09|lsst-lion1[05])
        ./lion_vldrive/setup
        ;;

    ## FIXME what are the right hosts for this?
    lsst-uno11)
        ./imanager/setup
        ;;

    ## FIXME what are the right hosts for this?
    lsst-uno06|comcam-hcu03)
        ./filter_changer/setup
        ;;
esac

case $shost in
    *-uno*|*-lion*|*-hcu*)

        f=/etc/sudoers.d/poweroff
        [ -e $f ] || cp ./power/sudo-poweroff $f

        f=/usr/local/libexec/poweroff
        [ -e $f ] || cp ./power/${f##*/} $f

        for f in CCS_POWEROFF CCS_REBOOT; do
            f=/usr/local/bin/$f
            [ -e $f ] || cp ./power/${f##*/} $f
        done
    ;;
esac


## TODO quadbox hosts.
case $shost in
    lsst-lion0[2-5])
        f=/usr/local/bin/CCS_QUADBOX_POWEROFF
        [ -e $f ] || cp ./power/${f##*/} $f
        ;;
esac


## Newer java version for font rescaling on big display.
[ $shost = lsst-vw01 ] && {

    jvmdir=/usr/lib/jvm         # somewhere in /usr/local better?
    jdkver=11.0.2
    jdktar=/root/openjdk-${jdkver}_linux-x64_bin.tar.gz # fixme

    if [ -e $jdktar ]; then
        tar -C $jvmdir -axf $jdktar
    else
        echo "WARNING skipping missing file: $jdktar"
    fi

    jdkccs=/etc/ccs/$jdkccs

    [ -e $jdkccs ] || \
        printf "export PATH=$jvmdir/jdk-$jdkver/bin:$PATH\n" > $jdkccs

    f=/etc/ccs/ccs-console.app
    grep -q ${jdkccs##*/} $f >& /dev/null || \
        printf "system.pre-execute=${jdkccs##*/}\n" >> $f

}                               # lsst-vw01


## FIXME only apply to "ccs" hosts.
## https://lsstc.slack.com/archives/GJXPVQWA0/p1558623946001400
## "To address message transfer delays we observed on the CCS cluster...
## [for] all nodes in running CCS applications"
## https://confluence.slac.stanford.edu/display/LSSTCAM/JGroups+Tuning+and+Performance
## FIXME change value for daq and other hosts. Do not replace prior value.
f=/etc/sysctl.d/99-lsst-daq-ccs.conf
[ -e $f ] || touch $f

value=18874368

for v in net.core.{wmem,rmem}_max; do
    grep -q "$v *= *$value" $f && continue
    sed -i "/$v/d" $f
    echo "$v = $value" >> $f

    /usr/sbin/sysctl -w $v=$value
done


## Graphics drivers.

## TODO better detection method.
case $shost in
    lsst-vw01|lsst-it01) nvidia=t ;;
    *) nvidia= ;;
esac

[ "$nvidia" ] && {

    ## This takes care of the /etc/kernel/postinst.d/ part,
    ## so long as the nvidia driver is installed with the dkms option.
    rpm --quiet -q dkms || yum -q -y install dkms

    f=/etc/modprobe.d/disable-nouveau.conf
    [ -s $f ] || cat <<EOF > $f
blacklist nouveau
options nouveau modeset=0
EOF

    grep -q "rdblacklist=nouveau" /etc/default/grub || {
        sed -i -e '/^GRUB_CMDLINE_LINUX=/ s/"$/ rdblacklist=nouveau"/' \
            /etc/default/grub
        grub2-mkconfig -o $grubfile
    }

    dracut -f

    ## TODO actually install the driver if possible.

}                               # $nvidia


exit 0
