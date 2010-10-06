#!/bin/sh

# init.d-script to control the racesow servers
# you also may want to add a cronjrob with the check command to ensure your servers are always running
# requires: screen, start-stop-deamon, quakestat
#
# Usage: racesow COMMAND [OPTIONS]...
# options can be specified in any combination and order
# --optionx --optiony
# -xy
# options without - or -- prefix are considered to be SERVERIDs which have to match the sections in the ini-file
# if no SERVERIDs are given, all sections from the config will be used.

# The user which should run the gameservers
GAMEUSER=racesow

# Name for the main screen the gameservers will run in
SCREEN_NAME=racesow

# Folder to store PID files (writeable)
PATH_PIDS=/home/racesow/pids

# Warsow root directory
PATH_WARSOW=/home/racesow/warsow-0.5

# The gameserver executable
GAMESERVER=wsw_server.x86_64

#Path quakestat
QUAKESTAT=quakestat

#Hostname or IP for qstat queries
HOST=localhost

# The start-stop-daemon executable
DAEMON=/sbin/start-stop-daemon

# ini-file for server configuration
CONFIG=/home/racesow/servers.ini

# DO NOT EDIT  BELOW THIS LINE
THISFILE=$0

# display the help for this script
function display_help
{
    echo "Usage: "`basename $THISFILE`" {start|stop|restart|check|cleanup} [OPTIONS]..."
    exit
}

# get the process id of the main screen
function get_main_screen_pid
{
    return `$SUDO screen -ls | pcregrep "\d+\.$SCREEN_NAME" | awk -F "." '{printf "%d",$1}'`
}

# Start a server loop for the given port
function gameserver_start
{
    get_main_screen_pid
    if (($? == 0 )); then
        echo "starting main screen."
        `$SUDO screen -dmS $SCREEN_NAME`
    fi

    if [ "$1" == "" ]; then
        for ID in $SERVERIDS; do
            gameserver_start $ID
        done
    else
	ENABLED=$(ini_get $CONFIG $1 enabled)
	REMOTE=$(ini_get $CONFIG $1 remote)
	if [ "$ENABLED" == "0" ]; then
	    echo "$1 is disabled. skipping..."
	    return 25
	elif [ "$REMOTE" == "1" ]; then
	    echo "$1 is a remote server, skipping..."
	    return 26
	fi
	
	
	
        PORT=$(ini_get $CONFIG $1 port)
        MOD=$(ini_get $CONFIG $1 mod)
        
        if [ "$MOD" == "" ]; then
            MOD=basewsw
        fi
        
        if [ "$PORT" != "" ]; then
            if [ ! -f $PATH_WARSOW/$MOD/cfgs/port_$PORT.cfg ]; then
                echo "WARNING: no config found for $1"
            fi
            gameserver_check_pid $1
            if (($? == 0)); then
                exec_command "start" $PORT $MOD "screen -S $SCREEN_NAME -X screen -t ${GAMEUSER}_$PORT"
            else
                echo "Server '$1' ($PORT) is already running"
            fi
            return 1
        else
            echo "Server '$1' is not configured in $CONFIG"
            return 23
        fi
    fi
}

#create-command
function exec_command
{
    STARTSTOP=$1
    PORT=$2
    SCREENCMD=$4
    MOD=$3
    
    if (($DEBUG == 1)); then
        DEBUGGER="gdb"
    fi

    CMD="$SUDO $SCREENCMD $DAEMON --pidfile $PATH_PIDS/$PORT.pid --make-pidfile $CHUID --$STARTSTOP --chdir $PATH_WARSOW $CHUID --exec $PATH_WARSOW/$GAMESERVER +set fs_game $MOD ${PORT_ARGS[$PORT]} +exec cfgs/port_"$PORT".cfg"
    if (($DRY == 1)); then
        echo $CMD
    else
        `$CMD > /dev/null`
    fi
}

# stop gameserver(s)
function gameserver_stop
{
    if [ "$1" == "" ]; then
        if [ $FORCE == 0 ]; then
            echo "really stop all servers? [y/n]:"
            read -t 5 in
            if [ "$in" != "y" ] && [ "$in" != "yes" ]; then
                echo "aborting..."
                return 42
            fi
        fi
        for ID in $SERVERIDS; do
            gameserver_stop $ID
        done
    else
        PORT=$(ini_get $CONFIG $1 port)
        if [ "$PORT" != "" ];then
            exec_command "stop" $PORT $MOD
            rm -f $PATH_PIDS/$1.pid
        else
            echo "Server '$1' is not configured in $CONFIG"
            return 23
        fi
    fi
}

# check if there is a pid for the server id
function gameserver_check_pid
{
    if [ ! -f $PATH_PIDS/$1.pid ]; then
        return 0
    fi
    SERVERPID=$(cat $PATH_PIDS/$1.pid)
    TEST=$(echo $SERVERPID | xargs ps -fp | grep $GAMESERVER)
    if [ "$TEST" == "" ]; then
        rm -f $PATH_PIDS/$1.pid
        return 0
    else
        return 1
    fi
}

# check if the server is running, kills hanging gameserver processes
function gameserver_check_gamestate
{
    if [ "$1" == "" ]; then
        for ID in $SERVERIDS; do
            gameserver_check_gamestate $ID
        done
    else
        PORT=$(ini_get $CONFIG $1 port)

	QSQUERY="$QUAKESTAT -warsows $HOST:$PORT -R"
       	QSRESPONSE=`$QSQUERY`
        if [ "$DRY" == "1" ]; then
		echo $QSQUERY
		echo "-------------------------"
		echo $QSRESPONSE
		echo "-------------------------"
		echo `echo $QSRESPONSE | pcregrep "$HOST:$PORT +(DOWN|no response)"`
		echo "-------------------------"
	        echo `echo $QSRESPONSE | pcregrep "gametype=race"`
                echo "-------------------------"
        else    
            TEST=`echo $QSRESPONSE | pcregrep "$HOST:$PORT +(DOWN|no response)"`
	    if [ "$TEST" != "" ]; then
	        echo "Server '$ID' ($PORT) is not reachable via qstat"
	        gameserver_check_pid $1
	        if (($? == 0)); then
	            echo "* server '$1' not found, starting on port $PORT"
	            gameserver_start $1
	        else
	            echo "* restarting server '$1' on port $PORT"
	            gameserver_stop $1
	            gameserver_start $1
	        fi
	    else
	        MOD=$(ini_get $CONFIG $1 mod)
	        if [ "$MOD" == "" ]; then
	            MOD=basewsw
	        fi
	        
	        TEST=`echo $QSRESPONSE | pcregrep "fs_game=$MOD"`
	        if [ "$TEST" == "" ]; then
	            echo "Server '$ID' ($PORT) is not running the expected mod ($MOD). restarting..."
	            gameserver_stop $1
	            gameserver_start $1
	        else
	            GT=$(ini_get $CONFIG $1 gametype)
	            if [ "$GT" != "" ]; then
 	                TEST=`echo $QSRESPONSE | pcregrep "gametype=$GT"`
	                if [ "$TEST" == "" ]; then
	                    echo "Server '$ID' ($PORT) is not running the expected gametype ($GT). restarting..."
                            gameserver_stop $1
                            gameserver_start $1
                        fi
                    fi
                fi
	    fi
	fi
    fi
}

# cleanup the gameserver's tempmodules folders
function gameserver_cleanup_tempmodules
{
    #todo
    echo not yet implemented...
}

# read a value from a simple .ini file
function ini_get
{
    eval `sed -e 's/[[:space:]]*\=[[:space:]]*/=/g' \
        -e 's/;.*$//' \
        -e 's/[[:space:]]*$//' \
        -e 's/^[[:space:]]*//' \
        -e "s/^\(.*\)=\([^\"']*\)$/\1=\"\2\"/" \
        < $1 \
        | sed -n -e "/^\[$2\]/,/^\s*\[/{/^[^;].*\=.*/p;}"`

    echo ${!3}
}

function ini_get_sections
{
    echo `sed -e "s/^[^\[].*//g" \
        -e "s/\]//g" \
        -e "s/\[//g" \
        -e "/^$/d" $1 \
        | tr "\n" " "`
}

# default options
INTERACTIVE=0
QUIET=0
FORCE=0
DRY=0
DEBUG=0

# read commandline options,
PCNT=0
IDCNT=0
for PARAM in $@
do
    # reads options in the form --longNameOpt
    if [ "${PARAM:0:2}" == "--" ]; then
        case $PARAM in
            --dry-run ) DRY=1 ;;
            --force ) FORCE=1 ;;
            --interactive ) INTERACTIVE=1 ;;
            --quiet ) QUIET=1 ;;
            --debug ) DEBUG=1 ;;
            * ) echo `basename $THISFILE`: invalid option $PARAM; exit ;;
        esac
    # reads opions in the forms -x and -xyz...
    elif [ "${PARAM:0:1}" == "-" ]; then
        PLEN=${#PARAM}
        for ((PPOS=1; PPOS < PLEN; PPOS++))
        do
            case ${PARAM:$PPOS:1} in
            d ) DRY=1 ;;
            g ) DEBUG=1 ;;
            f ) FORCE=1 ;;
            i ) INTERACTIVE=1 ;;
            q ) QUIET=1 ;;
            * ) echo `basename $THISFILE`: invalid option -${PARAM:$PPOS:1}; exit ;;
            esac
        done
    # any other options will be considered server IDs
    elif (($PCNT > 0)); then
        SERVERIDS="$SERVERIDS $PARAM"
        #SERVERIDS="$PARAM" #only use the last given port for now
        IDCNT=$(($IDCNT+1)) 
    fi
    PCNT=$(($PCNT+1)) 
done

if (($IDCNT == 0)); then
    SERVERIDS=$(ini_get_sections $CONFIG)
elif (($IDCNT == 1)); then
    SINGLEID=$SERVERIDS
    SERVERIDS=""
fi

if [ "$USER" != "$GAMEUSER" ]; then
    SUDO="sudo -u $GAMEUSER -H"
    #CHUID="--chuid $GAMEUSER:$GAMEUSER"
fi

case $1 in
    start ) gameserver_start $SINGLEID ;;
    stop ) gameserver_stop $SINGLEID ;;
    restart ) gameserver_stop $SINGLEID; gameserver_start $SINGLEID ;;
    check ) gameserver_check_gamestate $SINGLEID ;;
    cleanup ) gameserver_cleanup_tempmodules ;;
    * ) display_help ;;
esac
