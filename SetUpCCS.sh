#!/bin/bash
#
# script to set up the ccs environment: user ccs, group, sudoers, directories
#
#-------------------------------------------------------------------------------------------------------------------
set -e
#
#- to run this on a fresh machine you need to copy locally as in:
#  scp lsst-ss01:/u1/ir2admin/SetUpCCS.sh /tmp; sudo /tmp/SetUpCCS.sh
#  or it will be in:
#         /lnfs/lsst/ir2admin/SetUpCCS.sh, just run from there
#

#-------------------------------------------------------------------------------------------------------------------
#-- group and user for ccs
#
grep -q "^ccs:x:23000" /etc/passwd || /usr/sbin/adduser -c "CCS Operator Account" --groups dialout --create-home --uid 23000 ccs

#-------------------------------------------------------------------------------------------------------------------
#-- location for ccs software
#
if [ ! -d /opt/lsst/ccs ] ; then mkdir -p /opt/lsst/ccs; fi
stat -c %u:%g /opt/lsst/ccs | grep -q "23000:23000" || chown ccs.ccs /opt/lsst/ccs
if [ ! -d /opt/lsst/ccsadm ] ; then mkdir -p /opt/lsst/ccsadm; fi
stat -c %u:%g /opt/lsst/ccsadm | grep -q "23000:23000" || chown ccs.ccs /opt/lsst/ccsadm
#-- /lsst link management
if [ ! -h /lsst ] ; then ln -s /opt/lsst /lsst; fi
if [ -d /lsst/release ] ; then mv  /lsst/release /lsst/ccsadm/; fi
if [ -d /lsst/dev-package-lists ] ; then mv  /lsst/dev-package-lists /lsst/ccsadm/; fi
#-- log area
if [ ! -d /var/log/ccs ] ; then mkdir -p /var/log/ccs; fi
stat -c %u:%g /var/log/ccs | grep -q "0:23000" || $(chown root.ccs /var/log/ccs; chmod g+s /var/log/ccs; chmod a+rw /var/log/ccs)
#-- etc/ccs
if [ ! -d /etc/ccs ] ; then mkdir -p /etc/ccs; fi
stat -c %u:%g /etc/ccs | grep -q "0:23000" || $(chown root.ccs /etc/ccs; chmod g+srw /etc/ccs)
#-- etc/ccs/ccsGlobal.properties file management
if [ ! -e /etc/ccs/ccsGlobal.properties ] ; then touch /etc/ccs/ccsGlobal.properties; fi
grep "^org.lsst.ccs.level=INFO" /etc/ccs/ccsGlobal.properties >/dev/null || echo "org.lsst.ccs.level=INFO" >> /etc/ccs/ccsGlobal.properties
grep "^org.lsst.ccs.logdir=/var/log/ccs" /etc/ccs/ccsGlobal.properties >/dev/null || echo "org.lsst.ccs.logdir=/var/log/ccs" >> /etc/ccs/ccsGlobal.properties
#-- etc/ccs/ccsGlobal.properties file management
if [ ! -e /etc/ccs/udp_ccs.properties ] ; then touch /etc/ccs/udp_ccs.properties; fi
grep "^org.lsst.ccs.jgroups.ALL.UDP.bind_addr=$(hostname --fqdn)" /etc/ccs/udp_ccs.properties >/dev/null || echo "org.lsst.ccs.jgroups.ALL.UDP.bind_addr=$(hostname --fqdn)" >> /etc/ccs/udp_ccs.properties



#-------------------------------------------------------------------------------------------------------------------
#- add the dh account
grep -q "23001" /etc/passwd || /usr/sbin/adduser -c "LSST Data Handling Account" --groups dialout --create-home --uid 23001 dh

#-------------------------------------------------------------------------------------------------------------------
#- add and manage the lsstadm group
grep -q "^lsstadm:x:24000" /etc/group || groupadd --gid 24000 lsstadm
grep -q "^lsstadm:x:24000" /etc/group | grep ccs || gpasswd --add ccs lsstadm >/dev/null
grep -q "^lsstadm:x:24000" /etc/group | grep  dh || gpasswd --add  dh lsstadm >/dev/null

#-------------------------------------------------------------------------------------------------------------------
#-- sudoers configuration
#-- allows members of lsst-ccs unix group to run any command (and shell) as the "ccs" user
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

#-------------------------------------------------------------------------------------------------------------------

#- get nfs set up
#- need nfs programs
rpm --quiet -q nfs-utils || yum -y install nfs-utils

#- get rid of old /lnfs/lsst mount point if in use and entry in fstab
mount | grep -q lnfs && umount /lnfs/lsst
if [ ! -L /lnfs/lsst ] && [ -d /lnfs/lsst ] ; then rmdir /lnfs/lsst; fi
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

        [ -e $f ] && umount $f

        mkdir -p ${f%/*}

        grep -q "^$f" $auto_gpfs && continue

        printf "%-30s %s\n" "$f" "$h.slac.stanford.edu:&" >> $auto_gpfs

    done


    gpfs_autofs=/etc/auto.master.d/gpfs.autofs

    [ -e $gpfs_autofs ] || touch $gpfs_autofs

    ## NB need vers=3 to avoid problems with (bonded) wifi.
    ## FIXME only use this for aio hosts.
    grep -q $auto_gpfs $gpfs_autofs || \
        echo "/-	$auto_gpfs	vers=3" >> $gpfs_autofs


    ## Remove "sss" so as to avoid a bunch of SLAC NFS that we don't want.
    ## FIXME "Generated by Chef. Local modifications will be overwritten."
    sed -i 's/^automount:.*/automount:	files/' /etc/nsswitch.conf


    systemctl enable autofs
    systemctl start autofs

}                               # native_gpfs


#- fix up so old /lnfs path still works
if [ ! -d /lnfs ] ; then mkdir /lnfs; fi
if [ ! -L /lnfs/lsst ] ; then ln -s /gpfs/slac/lsst/fs2/u1 /lnfs/lsst; fi


#-------------------------------------------------------------------------------------------------------------------
#- dh software is in NFS
if [ ! -h /lsst/dh ] ; then ln -s /lnfs/lsst/dh /lsst/dh; fi
if [ ! -h /lsst/data ] ; then ln -s /lnfs/lsst/data /lsst/data; fi

#-------------------------------------------------------------------------------------------------------------------
#- install the correct java from nfs
jdkrpm=/lnfs/lsst/pkgarchive/jdk-8u112-linux-x64.rpm
javaver=$(rpm -qi -p ${jdkrpm} | gawk '/^Version/ {print $3}';)
javapkg=$(rpm -q -p ${jdkrpm})
rpm --quiet -q ${javapkg} || $(rpm -i ${jdkrpm})
java -version 2>&1 | grep ${javaver} || $(
   for cmd in java javac javaws jar jconsole ; do
      update-alternatives --install /usr/bin/${cmd} ${cmd} /usr/java/jdk${javaver}/bin/${cmd} 1000
      update-alternatives --set ${cmd} /usr/java/jdk${javaver}/bin/${cmd}
   done)
#-------------------------------------------------------------------------------------------------------------------
#- gdm and graphical stuff on workstations

rpm --quiet -q gdm && $(
      systemctl enable gdm
      systemctl set-default graphical.target
      yum remove -y gnome-initial-setup
      )
#------------------------------------------------------------------------------------------------------------------
#- selinux
setenforce 0
grep -q "SELINUX=enforcing" /etc/selinux/config && sed -i -e 's/enforcing/permissive/' /etc/selinux/config
#------------------------------------------------------------------------------------------------------------------
#- firewalld
rpm --quiet -q firewalld && $(
      systemctl status firewalld | grep -qv 'Loaded: masked'\
      && systemctl mask --now firewalld
      )
#------------------------------------------------------------------------------------------------------------------
#- ccs update-k5login
if [ ! -d /home/ccs/crontabs ] ; then mkdir /home/ccs/crontabs ; fi
if [ ! -e /home/ccs/crontabs/update-k5login ] || [ ! -x /home/ccs/crontabs/update-k5login ] ; then
   cat <<EOF >>/home/ccs/crontabs/update-k5login
#!/bin/bash
getent netgroup u-lsst-ccs |
 sed -e 's/(-,//g' |\
 sed -e 's/,)//g' |\
 sed -e 's/^u-lsst-ccs *//' |\
 tr ' ' '\n' |\
 sed -e 's/$/@SLAC.STANFORD.EDU/' > /tmp/.k5login
rsync --checksum /tmp/.k5login ~

EOF
   chown -R ccs:ccs /home/ccs/crontabs
fi
if [ ! -x /home/ccs/crontabs/update-k5login ] ; then chmod +x /home/ccs/crontabs/update-k5login ; fi
#- run update-k5login
sudo -u ccs /home/ccs/crontabs/update-k5login
#- update the crontab file if needed
crontab -u ccs -l | grep -q update-k5login ||\
echo "0,15,30,45 * * * * /home/ccs/crontabs/update-k5login" | crontab -u ccs -
#------------------------------------------------------------------------------------------------------------------
#
