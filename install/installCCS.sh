#!/bin/sh

#The first argument must be the environment IR2|ATS|IR2-Simulated
if [ $# -eq 0 ]; then
    echo One argument must be provided: the environment
    exit 1
fi

ENVIRONMENT=$1
NODE_NAME=$2

BASEDIR=$(dirname "$0")
DEV_PACKAGE_DIR="/lsst/ccsadm/dev-package-lists"
RELEASE_INSTALL_SCRIPT="/lsst/ccsadm/release/bin/install.py"
CCS_INSTALL_DIR="/lsst/ccs/"`date +%Y%m%d`

# Check if there is already an installation directory, in which case abort.
# What should be done in this case? Remove the directory or run the update script?
if [ -d "$CCS_INSTALL_DIR" ]; then
  echo Installation directory $CCS_INSTALL_DIR already exists. Exiting.
  exit
fi

VERIFY_USER=`$BASEDIR/verifyUser.sh ccs`

if [ "$VERIFY_USER" == 1 ] 
then

    # Check that the dev-package-lists github project is up to date.
    # If not abort.
    cd $DEV_PACKAGE_DIR
    gitPull=`git pull`
    if [[ $? != 0 ]]; then
	echo Something went wrong when updating $DEV_PACKAGE_DIR: $?
	exit
    fi
    gitStatus=`git status`
    if [[ $gitStatus != *"nothing to commit, working directory clean"* ]]; then
	echo Directory $DEV_PACKAGE_DIR is not up to date. Exiting.
	exit
    fi

    # Check that the install script exists. If not abort.
    if [ ! -f "$RELEASE_INSTALL_SCRIPT" ]; then
	echo The release package install script is not available at $RELEASE_INSTALL_SCRIPT
	exit
    fi    

    echo Performing new installation of CCS software in $CCS_INSTALL_DIR 

    if [ -z "$NODE_NAME" ]; then
	echo recalculating node name
	IN=`uname -n`
	arrIN=(${IN//./ })
	NODE_NAME=${arrIN[0]} 
    fi

    $RELEASE_INSTALL_SCRIPT --ccs_inst_dir $CCS_INSTALL_DIR $DEV_PACKAGE_DIR/$ENVIRONMENT/$NODE_NAME/ccsApplications.txt

else
    echo $VERIFY_USER
fi
