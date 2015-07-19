#!/bin/sh

IAM=`basename "$0"`
LOGFILE="/var/log/${IAM}.log"
NETWORK_USER="$1"
LOCAL_USER="$2"
SEARCHDIR="$3"
DO_ADDADMIN="$4"
WORKDIR=`dirname "$0"`
FIXOWNER="${WORKDIR}/fixchown.sh"
CMA="/System/Library/CoreServices/ManagedClient.app/Contents/Resources/createmobileaccount"
MIGRATE=DO

##############################################
#
#  USAGE
#  ---------------
#
#  Show how to use
#
##############################################
usage(){
cat <<__HELP

 use with sudo command like this;
 sudo $0 username_on_ActiveDirectory Local_username_to_migrate ActiveDirectory_SearchPath_for_DSCL [addadmin]

 if you want to just create mobile account from AD, set "none" to Local_username_to_migrate.
 The log file of this script is "${LOGFILE}".

__HELP
}
if [ `whoami` != root   ]; then usage; exit 1; fi

##############################################
# Logging
##############################################
logging(){
	LTIME=`date "+%Y/%m/%d %H:%M:%S"`
        /usr/bin/logger "${IAM}: $1"
        echo "[$LTIME] $1" >> "${LOGFILE}"
        echo "$1" 
}

##############################################
# Add a user to admin group
##############################################
addadmin(){
        ADDACCOUNT=$1
        isAdmin=`dseditgroup -o checkmember -m "${ADDACCOUNT}" admin | awk '{print $1}'`
        if [ $isAdmin = 'no' ]; then
                UU_ID=`dscl . -read /Users/"${ADDACCOUNT}" GeneratedUID | awk '{print $2}'`
                dscl . -append /Groups/admin GroupMembership "${ADDACCOUNT}"
                dscl . -append /Groups/admin GroupMembers "${UU_ID}"
        fi
}

logging "*****************************************************"
logging "[INFO] Script $0 $@ Started."

##############################################
# Before execute check
##############################################
# Arguments
if [ $# -le 2           ]; then usage; logging "[ERROR] Invalid Number of arguments."; exit 1; fi
if [ ! -x "$FIXOWNER"   ]; then logging "[ERROR] Helper script $FIXOWNER not fonund."; exit 3; fi
if [ ! -x "$CMA" ]; then
        logging "[ERROR] $CMA not found. Mobile Account could not be created."
        exit 1
fi

# Bind to AD?
BOUND=`/usr/sbin/dsconfigad -show | wc -l `
if [ $BOUND -eq 0 ]; then
	logging "[ERROR] This computer seems not to be bound to Active Directory yet."
	exit 2
fi

# Check AD domain
dscl "$SEARCHDIR" -read /Users > /dev/null 
CODE=$?
if [ $CODE -ne 0 ]; then
	logging "[ERROR] Invalid Active Directory domain was given: $SEARCHDIR."
	exit $CODE
fi
logging "[INFO] Active Directory domain was given: $SEARCHDIR."

# Add dsconfigad option
PREFERDOMAIN=`dsconfigad -show | grep "Active Directory Domain" | awk -F= '{print $2}'`
dsconfigad -alldomains disable                         \
 -localhome enable                                     \
 -mobile enable -mobileconfirm  disable                \
 -namespace domain -preferred $PREFERDOMAIN            \
 -restrictDDNS en99 -enablesso > /dev/null 2>&1

# Add Google Chrome Option for System Wide
CHROMEPLIST="/System/Library/User Template/Non_localized/Library/Preferences/com.google.Chrome"
defaults write "${CHROMEPLIST}" AuthSchemes 'negotiate,ntlm,basic,digest'
defaults write "${CHROMEPLIST}" AuthServerWhitelist "*.${PREFERDOMAIN}"

# Check value of each argument.
i=`echo $NETWORK_USER    | tr [:upper:] [:lower:]`; NETWORK_USER=$i
i=`echo $LOCAL_USER | tr [:upper:] [:lower:]`; LOCAL_USER=$i
if [ $LOCAL_USER = "none" ]; then 
	MIGRATE=DONOT
	LOCAL_USER=`uuidgen | tr -d '-'`
	logging "[INFO] Got it. None will be migrated. Just create a mobile account."
fi

# Check User acount of AD
dscl "$SEARCHDIR" -read /Users/$NETWORK_USER RecordName > /dev/null 2>&1
CODE=$?
if [ $CODE -ne 0 ]; then
	logging "[ERROR] User $NETWORK_USER not found in Active Directory."
	exit $CODE
fi
NETWORK_USERID=`dscl "$SEARCHDIR" -read /Users/$NETWORK_USER UniqueID | awk '{print $2}'`
logging "[INFO] User on Active Directory domain: $NETWORK_USER."

# Check User acount of local
if [ "$MIGRATE" != "DONOT" ]; then
	dscl . -read /Users/$LOCAL_USER RecordName > /dev/null 2>&1
	CODE=$?
	if [ $CODE -ne 0 ]; then
		logging "[ERROR] User $LOCAL_USER not found in DSLocal."
		exit $CODE
	fi
	logging "[INFO] Local User to migrate: $LOCAL_USER."
	LOCAL_USERID=`id -ur $LOCAL_USER`
	LOCAL_USERHOMEDIR=`dscl . -read /Users/$LOCAL_USER NFSHomeDirectory | awk '{print $2}'`
	logging "[INFO] Local user account to migurate: $LOCAL_USER"
	logging "[INFO] Local user account id to migurate: $LOCAL_USERID"
	logging "[INFO] Local user account Home Directory to migurate: $LOCAL_USERHOMEDIR"

	if [ $NETWORK_USERID -eq $LOCAL_USERID ]; then
		i="`dscl . -read /Users/$LOCAL_USER OriginalNodeName | tr -d '\n' | awk -F: '{print $2}'`"
		DIRNODE="`echo $i`"
		if [ "$DIRNODE" = "$SEARCHDIR" ];then
			logging "[INFO] $LOCAL_USER is a mobile account $NETWORK_USERID of $SEARCHDIR" 	
			logging "[INFO] Nothing to do. Bye!! (No need to migrate.)" 	
			exit 0
		fi
	fi
fi

# Check Record Name conflict
if [ $NETWORK_USER != $LOCAL_USER ]; then
	dscl . -read /Users/$NETWORK_USER RecordName > /dev/null 2>&1
	CODE=$?
	if [ $CODE -eq 0 ]; then
		logging "[ERROR] There is same name account in DSLOCAL. Can not migrate."
		exit 99 
	fi 
fi

# Check Real Name conflict
i="`dscl "$SEARCHDIR" -read /Users/$NETWORK_USER RealName | tail -1`"
ADREALNAME="`echo $i | tr [:upper:] [:lower:]`"
for i in `dscl . -list /Users RealName | awk -v LU="$LOCAL_USER" '$1 != LU {print $1}'  `
do
	j="`dscl . -read /Users/$i RealName | tail -1`"
	o="`echo $j`"
	LOCALREALNAME=`echo $j | tr [:upper:] [:lower:]`
	if [ "$ADREALNAME" = "$LOCALREALNAME" ]; then
		logging "[INFO] Real Name $o is conflicted."
		dscl . -change /Users/$i RealName "$o" "$o (changed)"
		logging "[INFO] Changed RealName to $o (changed)."
	fi
done

##############################################
# Migrate
##############################################
if [ $MIGRATE != "DONOT" ]; then
	# Check FileVault stauts
	# Is there another account which can decrypt?
	FVSTATUS=`fdesetup status | grep -c On `
	if [ $FVSTATUS -eq 1 ]; then 
		logging "[INFO] File Vault is enable."
		NUMofFVUSER=`fdesetup list | awk -F, -v LU=$LOCAL_USER '$1 != LU {print $0}' | wc -l `
		if [ $NUMofFVUSER -eq 0 ]; then
			logging "[ERROR] There will be none enable to decrypt of FileVault!!"
			logging "[ERROR] Add one more File vault user on this Mac."
			logging "[ERROR] Abort!"
			exit 98
		else
			logging "[INFO] `fdesetup list | awk -F, -v LU=$LOCAL_USER '$1 != LU {print $0}' `"
		fi
	fi

	# Preserve local accounts homedir
	TASK_ID=`uuidgen`
	mv $LOCAL_USERHOMEDIR ${LOCAL_USERHOMEDIR}_${TASK_ID}
	logging "[INFO] Home Directory of ${LOCAL_USER} was moved as ${LOCAL_USERHOMEDIR}_${TASK_ID}."

	# delete accunt
	dscl . -delete /Users/${LOCAL_USER}  
	if [ $? -ne 0 ]; then
		logging "[ERROR] Could not delete an user, ${LOCAL_USER}. This is unexepcted!"
		logging "[ERROR] Abort!"
		exit 1
	else
		logging "[INFO] Deleted user: ${LOCAL_USER}."
	fi
	rm -rf /var/log/com.apple.launchd.peruser.${LOCAL_USERID}
	rm -rf /var/db/launchd.db/com.apple.launchd.peruser.${LOCAL_USERID}
fi

# Create mobile account
RESULT=`$CMA -n $NETWORK_USER -h /Users/$NETWORK_USER -S 2>&1`
if [ $? -eq 0 ]; then
	logging "[INFO] Created an user, $NETWORK_USER as mobile account."
else
	logging "[ERROR] Could not create an user, $NETWORK_USER as mobile account. This is unexepcted!"
	logging "$RESULT"
	logging "[ERROR] Abort!"
	exit 1
fi

# Migrate Home Directory
if [ $MIGRATE != "DONOT" ]; then
	if [ -d "/Users/$NETWORK_USER" ]; then rm -rf  "/Users/$NETWORK_USER" ; fi

	mv "${LOCAL_USERHOMEDIR}_${TASK_ID}" "/Users/$NETWORK_USER"

	if [ "$LOCAL_USERHOMEDIR" != "/Users/$NETWORK_USER" ]; then
		ln -s "/Users/$NETWORK_USER" "$LOCAL_USERHOMEDIR" 
	fi

	# Add Google Chrome Option for User 
	CHROMEPLIST="/Users/$NETWORK_USER/Library/Preferences/com.google.Chrome"
	defaults write "${CHROMEPLIST}" AuthSchemes 'negotiate,ntlm,basic,digest'
	defaults write "${CHROMEPLIST}" AuthServerWhitelist "*.${PREFERDOMAIN}"
	chown $NETWORK_USER  "${CHROMEPLIST}.plist"

	# Fix owner ship of files and directories.
	logging "[INFO] Start fix owner ship from $LOCAL_USERID to $NETWORK_USERID. It will take plenty of time..."
	logging "[INFO] $FIXOWNER $LOCAL_USERID $NETWORK_USERID"
	/usr/sbin/chown -R $NETWORK_USER "/Users/$NETWORK_USER" 2> /dev/null
	"$FIXOWNER" $LOCAL_USERID $NETWORK_USERID 2> /dev/null
	logging "[INFO] Fixed owner ship. Thank you for waiting me."
fi

# Add admin groups
if [ `echo ${DO_ADDADMIN:-"not"} | tr [:upper:] [:lower:]` = "addadmin" ]; then
	addadmin $NETWORK_USER ;  logging "[INFO] $NETWORK_USER is now one of local administrator."
fi
logging "[INFO] Everything done."

exit 0
