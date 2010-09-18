#!/bin/sh

# init.d-script to control the racesow servers
# you also may want to add a cronjrob with the check command to ensure your servers are always running
# requires: screen, start-stop-deamon, quakestat
#
# Usage: racesow COMMAND [PORT] [OPTIONS]...
# options can be specified in any combination and order

# The user which should run the gameservers
GAMEUSER=warsow

# Name for the main screen the gameservers will run in
SCREEN_NAME=racesow

# Folder to store PID files (writeable)
PATH_PIDS=/home/warsow/pids

# Warsow root directory
PATH_WARSOW=/home/warsow/warsow-0.5

# The mod directory
MODDIR=racesow

# The gameserver executable
GAMESERVER=wsw_server.x86_64

#Path quakestat
QUAKESTAT=quakestat

# The start-stop-daemon executable
DAEMON=/sbin/start-stop-daemon

CONFIG=/home/zolex/initsow/example.ini

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
        PORT=$(ini_get $CONFIG $1 port)
        if [ "$PORT" != "" ];then
            if [ ! -f $PATH_WARSOW/$MODDIR/cfgs/port_$PORT.cfg ]; then
                echo "WARNING: no config found for $1"
            fi
            gameserver_check_pid $1
            if (($? == 0)); then
                exec_command "start" $1 "screen -S $SCREEN_NAME -X screen -t ${GAMEUSER}_$PORT"
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
    SCREENCMD=$3
    PORT=$(ini_get $CONFIG $2 port)
    ARGS=$(ini_get $CONFIG $2 args)
    
    CMD="$SUDO $SCREENCMD $DAEMON --pidfile $PATH_PIDS/$PORT.pid --make-pidfile $CHUID --$STARTSTOP --chdir $PATH_WARSOW $CHUID --exec $PATH_WARSOW/$GAMESERVER +set fs_game $MODDIR $ARGS +exec cfgs/port_"$PORT".cfg"
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
            exec_command "stop" $1
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
        HOST=$(ini_get $CONFIG $1 host)
        if [ "$HOST" == "" ]; then
            HOST="localhost"
        fi
        SERVERTEST=`$QUAKESTAT -warsows $HOST:$PORT | pcregrep "$HOST:$PORT +(DOWN|no response)"`
        if [ "$SERVERTEST" != "" ]; then
            echo "Server '$ID' ($PORT) is not reachable via qstat"
            gameserver_check_pid $1
            if (($? == 0)); then
                echo "* starting on port $PORT"
                gameserver_start $1
            else
                echo "* restarting on port $PORT"
                gameserver_stop $1
                gameserver_start $1
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
            --QUIET ) QUIET=1 ;;
            * ) echo `basename $THISFILE`: invalid option $PARAM; exit ;;
        esac
    # reads opions in the forms -x and -xyz...
    elif [ "${PARAM:0:1}" == "-" ]; then
        PLEN=${#PARAM}
        for ((PPOS=1; PPOS < PLEN; PPOS++))
        do
            case ${PARAM:$PPOS:1} in
            d ) DRY=1 ;;
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
