#!/bin/bash
#
# script to set up the ccs environment: user ccs, group, sudoers, directories
#
#------------------------------------------------------------------------------
# To run this script on a fresh machine, first get a local copy.
# The best method is to use:
# git clone https://github.com/lsst-camera-dh/ccs-infrastructure
# Or (but may not be as up-to-date as the above version):
#  rsync -a lsst-it01:/gpfs/slac/lsst/fs2/u1/ir2admin/ccs-infrastructure .
#  sudo ./ccs-infrastructure/SetUpCCS.sh
# or run directly from /lnfs/lsst/ir2admin/ccs-infrastructure/SetUpCCS.sh

set -e

PD=${0%/*}
[ "$PD" ] && cd "$PD"
[ -e ./${0##*/} ] || {
    echo "Cannot find source directory"
    exit 1
}

release_full=$(cat /etc/redhat-release)
release=${release_full##* release }
release=${release%%.*}

shost=${HOSTNAME%%.*}

my_system=

while read ip; do
    case $ip in
        134.79.*) my_system=slac ;;
        140.252.*|10.0.103.*) my_system=tucson ;;
        139.229.174.*) my_system=chile ;;
    esac
    [ "$my_system" ] && break
done < <(hostname -I | tr ' ' '\n')

if [ "$my_system" ]; then
    echo "my_system = $my_system"
else
    echo "Unable to identify network"
    exit 1
fi


## FIXME only works at slac
## Note that we need to mount gpfs before we can use this.
pkgarchive=/lnfs/lsst/pkgarchive    # /gpfs/slac/lsst/fs2/u1/pkgarchive
[ $my_system = slac ] || pkgarchive=/root

[ $release -ge 9 ] && {
    rpm -q --quiet yum-utils || yum -y install yum-utils
    yum-config-manager --enable crb
}

case $my_system in
    slac)
        timedatectl | grep -q "RTC in local TZ: yes" && {
            echo "Setting RTC to UTC"
            timedatectl set-local-rtc 0
            /usr/sbin/hwclock -w # should not be needed, but is?
        }

        fhost=$shost.slac.stanford.edu

        tempfile=/tmp/${0##*/}.$$
        trap "rm -f $tempfile" EXIT

        if [ $release -gt 7 ]; then

            for f in gcc g++ libffi-devel; do
                rpm --quiet -q $f || yum -q -y install $f
            done

            ## TODO is there a better way to accept the license?
            licdir=/etc/chef/accepted_licenses
            licfile=$licdir/chef_workstation

            [ -e $licfile ] || {

                licver=5.6.12
                for f in /opt/chef-workstation/embedded/lib/ruby/gems/*/gems/chef-cli-*; do
                    [ -e $f ] || continue
                    licver=${f##*-}
                    break
                done

                sed -e 's/infra-client/chef-workstation/g' \
                    -e 's/Infra Client/Workstation/g' \
                    -e "/product_version/ s/ [0-9.]*\$/ $licver/" \
                    $licdir/chef_infra_client > $licfile
            }

            knife node 2>&1 | grep -q 'node attribute' || \
                chef gem install knife-attribute

            ## As of 202312 chef limit_login does nothing.
            f=/etc/sssd/sssd.conf
            cp -a $f $f.BAK

            ## TODO should check this is going to the right config section.
            grep -q '^simple_allow_groups.*lsst-ccs' $f || {
                sed -i '/^simple_allow_groups *= */ s/$/, lsst-ccs/' $f
                grep -q '^simple_allow_groups.*lsst-ccs' $f || \
                    echo 'simple_allow_groups = lsst-ccs' >> $f
            }

            users=ccs

            ## Temporary accounts we may use during install.
            for u in ccs-temp ccs-local; do
                id $u >& /dev/null || continue
                users="$users, $u"
            done

            ## TODO set limit_login to existing ones of these:
            ## '["ccs", "ccs-temp", "ccs-local"]'

            grep -q '^simple_allow_users.*ccs' $f || {
                sed -i "/^simple_allow_users *= */ s/\$/, $users/" $f
                grep -q '^simple_allow_users.*ccs' $f || \
                    echo "simple_allow_users = $users" >> $f
            }

            systemctl restart sssd

            ## Exclude the limit_login part of the lsst role, since
            ## it uses a netgroup and so would not work on rhel8+.
            knife node attribute set $fhost yum_should "update nothing"
            knife node attribute set $fhost kernel_updatedefault "no"

        fi                      # $release -gt 7

        knife node show $fhost -Fjson > $tempfile

        ## This sets: limit_login, yum_should, kernel_updatedefault.
        ## We can relax the last two for some hosts, eg aios.
        [ $release -ge 7 ] || \
            grep -qF 'role[lsst]' $tempfile || \
                knife node run_list add $fhost 'role[lsst]'

        grep -q slac_crowdstrike $tempfile && \
            ! /opt/CrowdStrike/falconctl -g --tags 2>&1 | grep -q lsst && \
            /opt/CrowdStrike/falconctl -s --tags="lsst"

        ## Unchanged: uno, lion (hcus).
        case $shost in
            ## TODO: consider using "update security" (rather than "nothing")
            ## on non-hcus:
            ### *-dc*|*-mcm*|*-ss*|*-vs*|*-ir2daq*|*-ir2db*)
            ###     knife node attribute set $fhost yum_should "update security"
            ###     ;;
            *-it01|*-vw0[12])
                ## Leave kernel fixed for gpfs.
                grep -q "yum_should.*update everything" $tempfile || \
                    knife node attribute set $fhost \
                          yum_should "update everything"
                ;;
            *-aio*|*-vw*|*-lt*|*-vi*)
                grep -q "kernel_updatedefault.*yes" $tempfile || \
                    knife node attribute set $fhost kernel_updatedefault "yes"
                ## Options: "update security", "update nothing"
                grep -q "yum_should.*update everything" $tempfile || \
                    knife node attribute set $fhost \
                          yum_should "update everything"
                ;;
        esac
        rm -f $tempfile

        ## Slow. Maybe better done separately?
        ## FIXME. Also don't want this on servers.
        ## Although people sometimes want to eg use vnc,
        ## so it does end up being needed on servers too.
        ## "Server with GUI" instead? Not much smaller.
        gnome=GNOME
        [ $release -eq 7 ] && gnome='GNOME Desktop'

        ## FIXME list installed does not work on rhel9?
        yum group list installed | grep -qi "$gnome" || {
            echo "Installing gnome"
            yum -q -y groups install "$gnome"
            yum clean all >& /dev/null
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
packages=
[ $release -eq 7 ] && \
    packages="ntp devtoolset-8 centos-release-scl-rh rh-git218"


for f in epel-release git rsync emacs chrony nano screen sysstat unzip \
      kernel-headers kernel-devel clustershell maven \
      attr parallel gcc dkms usbutils $packages; do
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
    slac) [ $release -gt 7 ] || systemctl disable chronyd ;; # slac uses ntpd
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
getent passwd ccs >& /dev/null || \
    /usr/sbin/adduser -c "CCS Operator Account" --groups dialout \
                      --create-home --uid 23000 ccs

#------------------------------------------------------------------------------
#-- location for ccs software
#
for d in /opt/lsst/ccs /opt/lsst/ccsadm; do
    [ -d $d ] || mkdir -p $d
    stat -c %U:%G $d | grep -q "ccs:ccs" || chown ccs:ccs $d
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
    stat -c %U:%G $d | grep -q "root:ccs" && continue
    chown root:ccs $d
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
}


## Add the dh account, for etraveler (only used at slac).
[ $my_system != slac ] || \
    getent passwd dh >& /dev/null || \
    /usr/sbin/adduser -c "LSST Data Handling Account" \
                      --groups dialout --create-home --uid 23001 dh


#------------------------------------------------------------------------------
#- add and manage the lsstadm group
getent group lsstadm >& /dev/null || groupadd --gid 24000 lsstadm
groups ccs | grep -q lsstadm || \
    gpasswd --add ccs lsstadm >/dev/null

! getent passwd dh >& /dev/null || \
    groups dh | grep -q lsstadm || \
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

getent passwd dh >& /dev/null && {
    sudo_opt="${sudo_opt/(ccs)/(dh)}"
    grep -q "^$sudo_opt" $f || echo "$sudo_opt" >> $f
}

chmod 440 $f


[ $my_system = slac ] && {

    sudoers="gmorris marshall tonyj turri"
    for u in $sudoers; do
        f=/etc/sudoers.d/user-$u
        [ -e $f ] && continue
        echo "$u   ALL=ALL" > $f
        chmod 440 $f
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

        ## It would be nicer to only use eg "fs1" (rather than "fs1/g") here,
        ## but it seems as if the server is not set up to allow that.
        ## (Maybe this is an nfs3 issue?)
        f=/etc/auto.gpfs
        [ -e $f ] || cp ./autofs/${f##*/} $f

        while read mount rest; do
            [[ $mount == /gpfs* ]] || continue
            mount | grep -q $mount && umount $mount
            ## Not necessary.
            #mkdir -p ${mount%/*}
        done < $f


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

        f=/etc/auto.master.d/gpfs.autofs

        [ -e $f ] || \
            sed "s/OPTIONS/${opt}/" ./autofs/${f##*/}.template > $f


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

## Now we can use $pkgarchive.

#------------------------------------------------------------------------------

case $shost in
    lsst-it01|*-aio*|*-vw*)
        rpm --quiet -q zoom || rpm -Uvh $pkgarchive/zoom*.rpm || :
        ;;
esac

#- install the correct java from nfs

jdkrpm=$pkgarchive/zulu17.rpm

if [ -e $jdkrpm ]; then

    rpm --quiet -q zulu-17 || rpm -i ${jdkrpm} > /dev/null
else
    echo "WARNING skipping missing jdkrpm: $jdkrpm"
fi


jdkrpm=$pkgarchive/jdk-8u202-linux-x64.rpm

if [ -e $jdkrpm ]; then

    ## 1.8.0_202
    javaver=$(rpm -qi -p ${jdkrpm} | gawk '/^Version/ {print $3}';)
    ## jdk1.8-1.8.0_202-fcs.x86_64
    javapkg=$(rpm -q -p ${jdkrpm})
    rpm --quiet -q ${javapkg} || rpm -i ${jdkrpm} > /dev/null
    java -version 2>&1 | grep -q -F ${javaver} || {
        ## TODO the -amd64 suffux added some point between 112 and 202.
        javadir=/usr/java/jdk${javaver}-amd64
        for cmd in java javac javaws jar jconsole jstack; do
            update-alternatives --install /usr/bin/${cmd} ${cmd} \
                                $javadir/bin/${cmd} 1000
            update-alternatives --set ${cmd} $javadir/bin/${cmd}
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

[ $release -le 7 ] && \
    systemctl disable initial-setup-graphical initial-setup-text

## TODO does this still work in rhel9?
getenforce 2> /dev/null | grep -qi Enforcing && setenforce 0
grep -q "SELINUX=enforcing" /etc/selinux/config && \
    sed -i.ORIG -e 's/=enforcing/=permissive/' /etc/selinux/config


rpm --quiet -q firewalld || yum -q -y install firewalld

systemctl status firewalld | grep -q 'Loaded: masked' || \
    systemctl mask --now firewalld

## For some reason this gets added to eg rhel9 motd.
grep -q 'firewalld is active' /etc/motd && \
    sed -i.BAK '/firewalld is active/d' /etc/motd


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
    [ -e $f ] || cp ./firewalld/${f##*/} $f

    ## Whitelist all SLAC ips.
    f=/etc/fail2ban/jail.d/10-lsst-ccs.conf
    [ -e $f ] || cp ./fail2ban/${f##*/} $f

    ## SLAC logs to /var/log/everything instead of /var/log/secure.
    f=/etc/fail2ban/paths-overrides.local
    [ ! -e /var/log/everything ] || [ -e $f ] || cp ./fail2ban/${f##*/} $f
}                               # my_system = slac


#------------------------------------------------------------------------------
#- ccs update-k5login

## No Kerberos in SLAC rhel8+. In any case update-k5login uses netgroups,
## which do not exist in SLAC rhel8+. Will have to use sudo instead.
[ $my_system = slac ] && [ $release -le 7 ] && {

    [ -d ~ccs/crontabs ] || mkdir ~ccs/crontabs

    f=~ccs/crontabs/update-k5login
    if [ ! -e $f ] || [ ! -x $f ] ; then
        cp ./update-k5login $f
        chown -R ccs:ccs ~ccs/crontabs
    fi
    [ -x $f ] || chmod +x $f
    ##- run update-k5login
    sudo -u ccs $f
    ##- update the crontab file if needed
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
## https://lsstc.slack.com/archives/CCQBHNS0K/p1553877151009500
f=/etc/profile.d/lsst-ccs.sh
[ -e $f ] || cp ./profile.d/${f##*/} $f


## Make permissions like /tmp.
## TODO improve partitioning scheme.
[ -d /scratch ] && grep -q "/scratch " /etc/mtab && chmod 1777 /scratch


## Change the default for home directories.
## TODO seems like all users should be in the same group though,
## rather than each having their own?
sed -i.ORIG -e 's/^UMASK.*/UMASK 022/' \
    -e 's/^HOME_MODE.*/HOME_MODE 0755/' /etc/login.defs

chmod 755 /home/*/        # may not be appropriate for system accounts


## Applications menu.

f=/etc/xdg/menus/applications-merged/lsst.menu
mkdir -p ${f%/*}
[ -e $f ] || cp ./desktop/${f##*/} $f

f=/usr/share/desktop-directories/lsst.directory
mkdir -p ${f%/*}
[ -e $f ] || cp ./desktop/${f##*/} $f

d=/usr/share/applications
mkdir -p $d
for f in console.{prod,dev} shell.{prod,dev}; do

    t=${f#*.}                   # prod or dev

    app=${f%.*}                 # console or shell

    f=lsst.ccs.$f.desktop

    [ -e $d/$f ] && continue

    case $t in
        prod) desc="production" ;;
        dev) desc="development" ;;
    esac

    case $app in
        console) terminal=false ;;
        shell) terminal=true ;;
    esac

    sed -e "s/APP/$app/g" -e "s/VERSION/$t/g" \
        -e "s/TERMINAL/$terminal/" -e "s/DESC/$desc/" \
        ./desktop/lsst.ccs.APP.VERSION.desktop.template > $d/$f
done


## FIXME not a great icon.
f=/usr/share/icons/lsst_appicon.png
mkdir -p ${f%/*}
[ -e $f ] || cp ./desktop/lsst_appicon.png $f


## EPEL
## FIXME graphical hosts only.
rpm --quiet -q gdm && {
    ## This seems to be the smallest WM one can install.
    rpm -q --quiet icewm || yum -q -y install icewm || true
    rpm -q --quiet x2goclient || \
        yum -q -y install x2goclient x2goserver x2godesktopsharing || true
    if [ $release -eq 7 ]; then
        yum -y groupinstall 'MATE Desktop'
    else
        yum -y install mate-desktop mate-applets mate-menu mate-panel \
            mate-session-manager mate-terminal mate-themes mate-utils \
            marco caja
    fi
}

f=/etc/sudoers.d/x2goserver
[ -e $f ] && chmod 440 $f


## cron
## We assume that you ran this script via ./ from a git checkout
## of the script repository.
cp -a ./ccs-sudoers-services /etc/cron.hourly/ || true

cp ./ccs-log-compress /etc/cron.daily/ || true


grep -q ^HISTFILESIZE /root/.bashrc || \
    printf "\nexport HISTFILESIZE=1000000\n" >> /root/.bashrc

grep -q ^HISTSIZE /root/.bashrc || \
    printf "\nexport HISTSIZE=50000\n" >> /root/.bashrc


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
    grep -q "root@lsst-ss01" $f || cat ./ssh/${f##*/} >> $f

    ## FIXME this won't work because until we get this key we cannot login
    ## to other hosts. Need a common file-system (eg nfs).
    ## FIXME ds9 keys do not work in rhel9+. If we add an ed25519 key,
    ## chef removes it. TODO modify chef.
    [ $release -ge 9 ] || \
        rsync -aX lsst-mcm:.ssh/id_dsa .ssh/ || \
        echo "Failed to copy /root/.ssh/id_dsa - push from another host"

    ## Chef manages /etc/ssh/ssh_known_hosts
    rsync -aX lsst-mcm:/etc/ssh/ssh_known_hosts_local /etc/ssh/ || \
        echo "Failed to copy /etc/ssh/ssh_known_hosts_local - push from another host"
}                               # my_system = slac


./monit/setup $my_system || echo "WARNING: problem setting up monit"


./mrtg/setup || echo "WARNING: problem setting up mrtg"


## systemd mail on failure utilities.
cp ./systemd/systemd-email /usr/local/libexec/
cp ./systemd/status-email-user@.service /etc/systemd/system/
cp ./systemd/systemd-email.txt /etc/ccs/systemd-email


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
        [ -e $f ] || {
            ## Note: asked not to modify DAQ network interfaces.
            sed "s/DAQ_INTERFACE/DISABLED-$iface/" \
                ./network/${f##*/}.template > $f
            chmod 755 $f
        }

        ;;

    *-vw[0-9][0-9])
        grep -q ^AutomaticLogin /etc/gdm/custom.conf || \
            sed -i.ORIG '/^\[daemon.*/a\
AutomaticLogin=ccs\
AutomaticLoginEnable=true' /etc/gdm/custom.conf
        ;;

    *db[0-9][0-9])
        rpm -q --quiet mariadb-server || yum -q -y install mariadb-server
        systemctl enable mariadb

        ## TODO more cases?
        datadir=/home/mysql
        for d in /lsst-ir2db01 /data; do
            [ -e $d ] || continue
            datadir=$d/mysql
            break
        done

        case $my_system in
            slac) ccsdb=ir2dbprod ;;
            tucson) ccsdb=comcamdbprod ;;
            *) ccsdb=ccsdbprod ;; # TODO?
        esac

        ccsdbpasswd=
        read ccsdbpasswd < $pkgarchive/ccsdbpasswd || : ## FIXME

        if [ -e ${datadir%/*} ]; then
            [ -e $datadir ] || {
                mkdir -p $datadir
                chown mysql:mysql $datadir
                chmod 755 $datadir
            }
        else
            echo "WARNING: skipping creation of $datadir"
        fi

        f=/etc/my.cnf.d/zzz-lsst-ccs.cnf
        [ -e $f ] || {
            sed "s|DATADIR|${datadir}|g" ./db/${f##*/}.template > $f
            [ -d /scratch ] || sed -i '/^tmpdir/d' $f
        }

        ## Next:
        ## Create empty db called called comcamdbprod;
        ## add ccs account with all privs on that db;
        ## localdb -u to create tables.
        if systemctl start mariadb; then
            mysql="mysql -u root -e"
            $mysql "create database $ccsdb;"
            if [ "$ccsdbpasswd" ]; then
                $mysql "grant all on $ccsdb.* to 'ccs'@'%' identified by '$ccsdbpasswd';"
                $mysql "grant all on $ccsdb.* to 'ccs'@'localhost' identified by '$ccsdbpasswd';"
            else
                echo "WARNING: not granting ccs privileges on $ccsdb"
            fi
            ## Remove some dubious defaults.
            $mysql "drop database test;"
            $mysql "delete from mysql.user where User='';"

            $mysql "flush privileges;"

        else
            echo "WARNING: skipping creation of database"
        fi

        ;;

    *fcs[0-9][0-9]|lsst-lion18|lsst-lion03)
        ./lion_canbus/setup
        ;;

    ## FIXME what are the right hosts for this?
    lsst-lion09|lsst-lion1[05])
        ./lion_vldrive/setup
        ;;

    ## FIXME what are the right hosts for this?
    lsst-uno1[13]|lsst-uno08)
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
    jdktar=$pkgarchive/openjdk-${jdkver}_linux-x64_bin.tar.gz

    [ -e $jvmdir/jdk-$jdkver ] || {
        if [ -e $jdktar ]; then
            tar -C $jvmdir -axf $jdktar
        else
            echo "WARNING skipping missing file: $jdktar"
        fi
    }


    ## javafx is not included in this version.
    ## https://openjfx.io/openjfx-docs/#install-javafx
    jfxver=$jdkver              # coincidence?
    jfxzip=$pkgarchive/openjfx-${jfxver}_linux-x64_bin-sdk.zip
    jfxdest=$jvmdir/javafx-sdk-$jfxver

    ## TODO To use this, we need to add to the java command line:
    ## -p $jvmdir/javafx-sdk-$jfxver/lib --add-modules javafx.controls
    [ -e $jfxdest ] || {
        if [ -e $jfxzip ]; then
            unzip -q -d $jvmdir $jfxzip
        else
            echo "WARNING skipping missing file: $jfxzip"
        fi
    }


    jdkccs=/etc/ccs/jdk11

    [ -e $jdkccs ] || \
        printf "export PATH=$jvmdir/jdk-$jdkver/bin:\$PATH\n" > $jdkccs

    f=/etc/ccs/ccs-console.app
    [ -e $f ] || sed -e "s|JFXLIB|${jfxdest}/lib|" \
                     -e "s/JDKCCS/${jdkccs##*/}/" ./ccs/${f##*/}.template > $f
}                               # lsst-vw01


## FIXME only apply to "ccs" hosts.
## https://lsstc.slack.com/archives/GJXPVQWA0/p1558623946001400
## "To address message transfer delays we observed on the CCS cluster...
## [for] all nodes in running CCS applications"
## https://confluence.slac.stanford.edu/display/LSSTCAM/JGroups+Tuning+and+Performance
## FIXME change value for daq and other hosts. Do not replace prior value.
f=/etc/sysctl.d/99-lsst-daq-ccs.conf
[ -e $f ] || {
    cp ./sysctl/${f##*/} $f

    /usr/sbin/sysctl -p $f
}


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
    [ -s $f ] || cp ./nvidia/${f##*/} $f

    grep -q "rdblacklist=nouveau" /etc/default/grub || {
        sed -i -e '/^GRUB_CMDLINE_LINUX=/ s/"$/ rdblacklist=nouveau"/' \
            /etc/default/grub
        grub2-mkconfig -o $grubfile
    }

    dracut -f

    ## TODO actually install the driver if possible.

}                               # $nvidia


exit 0
