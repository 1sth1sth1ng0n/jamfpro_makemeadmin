#!/bin/bash

#===============================================================================
#          FILE: make-me-admin.sh
#         USAGE: jamf-pro self service policy
#   DESCRIPTION: elevate logged in user to admin for set time period
#       OPTIONS: computer will be added to static computer group using jamf api
#                this can be initiated from various cloud compute funtions
#  REQUIREMENTS: sap priviliges app cli to be installed first
#          BUGS: remove from group api call hangs ss if comp is not found
#         NOTES: will respect StartInterval incl. reboot or logout etc
#                PrivilegesCLI extracted from app bundle + daemon and helper tool
#      REVISION:  0.9
#===============================================================================

loggedInUser=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
JAMFHELPER='/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper'
icon='/Library/Application Support/JAMF/bin/logo.png'
BackUpLog="/var/log/makeMeAdmin.log"

if [[ ! "$BackUpLog" ]]; then
  /usr/bin/touch "$BackUpLog"
fi

# Provides logging of the script's actions
ScriptLogging(){

    DATE=$(date +%Y-%m-%d\ %H:%M:%S)
    LOG="$BackUpLog"
    echo "$DATE" "$1" >> $LOG
}


# admin elevation duration interval (seconds)
interval=$4
# admin elevation duration interval (minutes)
min_interval=$(($interval / 60))

# jamf api
apiURL='https://company.corp.com:8443'
apiUser=$5
apiPass=$6
group=$7
action='deletions' # remove device from static group
#action='additions' # add device to static group

# JAMF Helper prompt function, 1 button
prompt_function1(){

  JAMFHELPER_ARGS1=(\
      -windowType utility \
      -title  "$1" \
      -heading "$2" \
      -icon "$icon" \
      -alignHeading left \
      -description "$3" \
      -alignDescription left \
      -button1 "$4" \
      )

"$JAMFHELPER" "${JAMFHELPER_ARGS1[@]}"
}

# JAMF Helper prompt function, 2 button
prompt_function2(){

  JAMFHELPER_ARGS2=(\
      -windowType utility \
      -title  "$1" \
      -heading "$2" \
      -icon "$icon" \
      -alignHeading left \
      -description "$3" \
      -alignDescription left \
      -button1 "$4" \
      -button2 "$5" \
      )

"$JAMFHELPER" "${JAMFHELPER_ARGS2[@]}"
}

# JAMF Helper prompt function countdown
prompt_function3(){

  JAMFHELPER_ARGS2=(\
      -windowType utility \
      -title  "$1" \
      -heading "$2" \
      -icon "$icon" \
      -alignHeading left \
      -description "$3" \
      -alignDescription left \
      -timeout "$interval" \
      -countdown \
      -alignCountdown center \
      -lockHUD
      )

"$JAMFHELPER" "${JAMFHELPER_ARGS2[@]}"
}

ScriptLogging "Starting...."

# get hostname
host=$(scutil --get ComputerName)

# get serial number
sn=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
ScriptLogging "Serial Number = $sn"

# get id
answer=$(/usr/bin/curl -s -H "Content-Type: text/xml" -u ${apiUser}:${apiPass} 
${apiURL}/JSSResource/computers/serialnumber/$sn/subset/general )

jamfID=$(echo $answer | xmllint --xpath '/computer/general/id/text()' -) 
ScriptLogging "Jamf ID = $jamfID"

# create binary daemon plist to revoke access after set time
ScriptLogging "creating launchdaemon"
/usr/bin/defaults write /Library/LaunchDaemons/com.company.removeAdmin.plist Label -string 
"com.company.removeAdmin"
/usr/bin/defaults write /Library/LaunchDaemons/com.company.removeAdmin.plist ProgramArguments -array -string 
/bin/sh -string "/Library/Application Support/JAMF/bin/removeAdminRights.sh"
/usr/bin/defaults write /Library/LaunchDaemons/com.company.removeAdmin.plist StartInterval -integer $interval
/usr/bin/defaults write /Library/LaunchDaemons/com.company.removeAdmin.plist RunAtLoad -boolean yes
/usr/bin/defaults write /Library/LaunchDaemons/com.company.removeAdmin.plist StandardErrorPath 
"/private/var/userToRemove/err.err"
/usr/bin/defaults write /Library/LaunchDaemons/com.company.removeAdmin.plist StandardOutPath 
"/private/var/userToRemove/out.out"
/usr/sbin/chown root:wheel /Library/LaunchDaemons/com.company.removeAdmin.plist
/bin/chmod 644 /Library/LaunchDaemons/com.company.removeAdmin.plist

# load the daemon to start the revocation countdown - load it here before the revoke script is created
/bin/launchctl load /Library/LaunchDaemons/com.company.removeAdmin.plist
# allow time for daemon to start
/bin/sleep 5

# store user to be removed - a variable would not be persistent across reboots
if [ ! -d /private/var/userToRemove ]; then
	mkdir /private/var/userToRemove
	echo $loggedInUser >> /private/var/userToRemove/user
    echo $host >> /private/var/userToRemove/host
else
	echo $loggedInUser >> /private/var/userToRemove/user
    echo $host >> /private/var/userToRemove/host
fi

cat << 'EOF' > /Library/Application\ Support/JAMF/bin/removeAdminRights.sh
if [[ -f /private/var/userToRemove/user ]]; then
	userToRemove=$(cat /private/var/userToRemove/user)
    host=$(cat /private/var/userToRemove/host)
	echo "Removing $userToRemove's admin privileges on $host"
    # we use the sap privs tool as it does not require a reboot to demote a user
    sudo -u $userToRemove /usr/local/bin/PrivilegesCLI --remove
    /bin/sleep 2
    echo "Stopping daemon"
    /bin/launchctl bootout system /Library/LaunchDaemons/corp.sap.privileges.helper.plist
    echo "Initiating self destruct sequence..."
	/bin/rm -f /private/var/userToRemove/user
    /bin/rm -f /Library/LaunchDaemons/com.company.removeAdmin.plist
    # remove all sap stuff
    /bin/rm -rf /usr/local/bin/PrivilegesCLI
    /bin/rm -f /Library/LaunchDaemons/corp.sap.privileges.helper.plist
    /bin/rm -f /Library/PrivilegedHelperTools/corp.sap.privileges.helper
    # recon to update user admin status is Jamf Pro
    /usr/local/bin/jamf recon &
    # remove this script
    /bin/rm -f "$0"
    # we cannot unload the daemon as the path no longer exists - just remove it from launchd
    /bin/launchctl remove com.company.removeAdmin
fi
EOF

# elevate privs now
echo "Starting daemon"
/bin/launchctl bootstrap system /Library/LaunchDaemons/corp.sap.privileges.helper.plist
/bin/sleep 2
ScriptLogging "Elevating admin priviliges for ${loggedInUser}"
sudo -u $loggedInUser /usr/local/bin/PrivilegesCLI --add

# move ss out the way
/usr/bin/osascript -e 'tell application "System Events" to set visible of process "Self Service" to false'

# not capturing anything here
wrapper=$(prompt_function3 "Make Me Admin" "You now have admin privileges on this computer." "Please peform your 
required action before the timer expires." &)

# remove computer from policy scope so it cannot be run again - user will need to make a new request to be added
ScriptLogging "Removing this computer from the policy scope"
curl -sSkiu ${apiUser}:${apiPass} \
${apiURL}/JSSResource/computergroups/id/${group} \
-H "Content-Type: text/xml" \
-X PUT \
-d "<computer_group><computer_${action}>
<computer><id>${jamfID}</id></computer>
</computer_${action}></computer_group>"

ScriptLogging "....Done"

# recon to update user admin status is Jamf Pro
/usr/local/bin/jamf recon &

exit 0
