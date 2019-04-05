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
#--
#-- files
if [ ! -e /etc/sudoers.d/group-lsst-ccs ] ; then echo "%lsst-ccs ALL = (ccs) ALL" > /etc/sudoers.d/group-lsst-ccs; fi
if [ ! -e /etc/sudoers.d/user-turri ] ; then echo "turri   ALL=ALL" > /etc/sudoers.d/user-turri; fi
if [ ! -e /etc/sudoers.d/user-tonyj ] ; then echo "tonyj   ALL=ALL" > /etc/sudoers.d/user-tonyj; fi
if [ ! -e /etc/sudoers.d/user-marshall ] ; then echo "marshall   ALL=ALL" > /etc/sudoers.d/user-marshall; fi

#-- content of files

grep "^%lsst-ccs ALL = (ccs) ALL" /etc/sudoers.d/group-lsst-ccs >/dev/null || echo "%lsst-ccs ALL = (ccs) ALL" >> /etc/sudoers.d/group-lsst-ccs
grep "^%lsst-ccs ALL = (dh) ALL" /etc/sudoers.d/group-lsst-ccs >/dev/null || echo "%lsst-ccs ALL = (dh) ALL" >> /etc/sudoers.d/group-lsst-ccs
#-------------------------------------------------------------------------------------------------------------------
#- get nfs set up
#- need nfs programs
rpm --quiet -q nfs-utils || yum -y install nfs-utils

#- first the fs2 small area
#- get rid of old /lnfs/lsst mount point if in use and entry in fstab
mount | grep -q lnfs && umount /lnfs/lsst
if [ ! -L /lnfs/lsst ] && [ -d /lnfs/lsst ] ; then rmdir /lnfs/lsst; fi
grep -q "/lnfs/lsst" /etc/fstab && sed -i -e '/\/lnfs\/lsst/d' /etc/fstab


#- deal with nfs or gpfs mount of /gpfs/slac/lsst/fs2
#- check if gpfs native and if not then if not a directory, make one
if [ ! -d /gpfs/slac/lsst/fs2/u1 ] ; then mkdir -p /gpfs/slac/lsst/fs2/u1; fi
grep -q "^lsst-fs2" /etc/fstab ||\
   grep -q "lsst-ss01:/gpfs/slac/lsst/fs2/u1" /etc/fstab ||\
   cat <<EOF >>/etc/fstab
#
#-- LSST IR2 GPFS filesystem mounted as NFS
#
lsst-ss01:/gpfs/slac/lsst/fs2/u1  /gpfs/slac/lsst/fs2/u1   nfs defaults 0 0

EOF
sleep 1

#- mount it
grep -q "^lsst-fs2" /etc/fstab ||\
mountpoint -q /gpfs/slac/lsst/fs2/u1 || mount /gpfs/slac/lsst/fs2/u1
#- fix up so old /lnfs path still works
if [ ! -d /lnfs ] ; then mkdir /lnfs; fi
if [ ! -L /lnfs/lsst ] ; then ln -s /gpfs/slac/lsst/fs2/u1 /lnfs/lsst; fi


#- mount /gpfs/slac/lsst/fs1 via NFS if it is not already mounted
if [ ! -d /gpfs/slac/lsst/fs1/g ] ; then mkdir -p /gpfs/slac/lsst/fs1/g; fi
grep -q "^lsst-fs1" /etc/fstab || \
   grep -q "lsst-ss01:/gpfs/slac/lsst/fs1/g" /etc/fstab || \
   cat <<EOF >>/etc/fstab
#
#-- LSST IR2 GPFS filesystem mounted as NFS
#
lsst-ss01:/gpfs/slac/lsst/fs1/g  /gpfs/slac/lsst/fs1/g  nfs defaults 0 0

EOF
sleep 1
grep -q "^lsst-fs1" /etc/fstab ||\
mountpoint -q /gpfs/slac/lsst/fs1/g || mount /gpfs/slac/lsst/fs1/g

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
