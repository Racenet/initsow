#!/bin/sh

# init.d-script to control the racesow servers
# you also may want to add a cronjrob with the check command to ensure your servers are always running
# requires: screen, start-stop-deamon, quakestat
#
# Usage: racesow COMMAND [PORT] [OPTIONS]...
# options can be specified in any combination and order

# The user which should run the gameservers
GAMEUSER=warsow

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

#Hostname or IP for qstat queries
HOST=localhost

# The start-stop-daemon executable
DAEMON=/sbin/start-stop-daemon

# Space-separeted list of available gameserver ports
PORTS="50001 50002 50003"

# Port-specific arguments to wsw_server executable
PORT_ARGS[50002]="+set fs_usehomedir 0 +set fs_cdpath /home/racesow/.jump-it"

# DO NOT EDIT  BELOW THIS LINE

VERBOSE=0
FORCE=0

printf "%d" $2 > /dev/null 2>&1
if [ $? == 0 ]; then
        PORT=$2
fi

for PARAM in $@
do
        if [ "${PARAM:0:2}" == "--" ]; then
                case $PARAM in
                        --verbose ) VERBOSE=1 ;;
                        --force ) FORCE=1 ;;
                        * ) echo `basename $0`: invalid option $PARAM; exit ;;
                esac
        elif [ "${PARAM:0:1}" == "-" ]; then

                PLEN=${#PARAM}
                for ((PPOS=1; PPOS < PLEN; PPOS++))
                do
                        case ${PARAM:$PPOS:1} in
                                v ) VERBOSE=1 ;;
                                f ) FORCE=1 ;;
                                * ) echo `basename $0`: invalid option -${PARAM:$PPOS:1}; exit ;;
                        esac
                done
        fi
done

if [ "$USER" != "$GAMEUSER" ]; then
        SUDO="sudo -u $GAMEUSER -H"
        CHUID="--chuid $GAMEUSER:$GAMEUSER"
else
        SUDI=""
        CHUID=""
fi

THISFILE=$0
function display_help
{
	echo "Usage: "`basename $THISFILE`" {start|stop|check} [PORT] [OPTIONS]..."
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
        if [ "$?" == "0" ]; then
                        echo "starting main screen."
                `$SUDO screen -dmS $SCREEN_NAME`
        fi

        if [ "$1" == "" ]; then
                for PORT in $PORTS; do
                        gameserver_start $PORT
                done
        else
                PORTCHECK=$(echo $PORTS | grep $1)
                if [ "$PORTCHECK" != "" ];then
                        if [ ! -f $PATH_WARSOW/$MODDIR/cfgs/port_$1.cfg ]; then
                                        echo "WARNING: no config found for $1"
                                fi
                                gameserver_check_pid $1
                                if [ $? == 0 ]; then                            
                                        exec_command "start" $1 "screen -S $SCREEN_NAME -X screen -t ${GAMEUSER}_$1"
                                else
                                        echo "server $1 is already running"
                                fi
                                return 1
                        else
                                echo "server $1 is not configured"
                        fi
        fi
}

#create-command
function exec_command
{
        STARTSTOP=$1
        PORT=$2
        SCREENCMD=$3
        
        CMD="$SUDO $SCREENCMD $DAEMON --pidfile $PATH_PIDS/$PORT.pid --make-pidfile $CHUID --$STARTSTOP --chdir $PATH_WARSOW $CHUID --exec $PATH_WARSOW/$GAMESERVER +set fs_game $MODDIR ${PORT_ARGS[$PORT]} +exec cfgs/port_"$PORT".cfg"
#       echo $CMD
        `$CMD > /dev/null`
}

# stop gameserver(s)
function gameserver_stop
{                                         
        if [ "$1" == "" ]; then
                if [ $FORCE == 0 ]; then
                        echo really stop all servers? [yes/no]:
                        read -t 5 in
                        if [ "$in" != "y" ] && [ "$in" != "yes" ]; then
                                echo aborting...
                                return 42
                        fi
                fi
                for PORT in $PORTS; do
                        gameserver_stop $PORT
                done
        else
                PORTCHECK=$(echo $PORTS | grep $1)
                if [ "$PORTCHECK" != "" ];then

                        echo $1
                        exec_command "stop" $1
                        rm -f $PATH_PIDS/$1.pid

                else
                        echo "server $1 is not configured"
                        return 23
                fi
        fi
}

# Kill server loop with the given port
function gameserver_kill
{
        if [ "$1" == "" ]; then
                echo "you need to specify a port for killing a server"
                exit
        else
                PORTCHECK=$(echo $PORTS | grep $1)
                if [ "$PORTCHECK" != "" ]; then
                        gameserver_check_pid $1
                        if [ $? == 1 ]; then
                                echo "killing server warsow://$HOST:$1"
                                kill -n 15 `cat $PATH_PIDS/$1.pid`
                                rm -f  $PATH_PIDS/$1.pid
                        else
                                echo "server $1 is not running"
                                return 56
                        fi
                else
                        echo "server $1 is not configured"
                        return 23
                fi
        fi
}

# check if server on port $1 is running, also removes old pidfiles if necesary
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
                for PORT in $PORTS; do
                        gameserver_check_gamestate $PORT
                done
        else
                SERVERTEST=`$QUAKESTAT -warsows $HOST:$1 | pcregrep "$HOST:$1 +(DOWN|no response)"`
#               echo "$QUAKESTAT -warsows $HOST:$1 | pcregrep \"$HOST:$1 +(DOWN|no response)\""
                if [ "$SERVERTEST" != "" ]; then
                        echo "warsow://$HOST:$1 is not reachable via qstat"
                        
                        echo "* trying to find the process by it's pid"
                        gameserver_check_pid $1
                        if [ $? == 0 ]; then
                                echo "* gameserver not found, starting on port $1"
                                gameserver_start $1
                        else
                                echo "* restarting gameserver on port $1"
                                gameserver_stop $1
                                gameserver_start $1
                        fi
                fi
        fi
}

# Check and run the action
case $1 in
        start ) gameserver_start $PORT ;;
        stop ) gameserver_stop $PORT ;;
        check ) gameserver_check_gamestate $PORT ;;
        * ) display_help ;;
esac