#!/usr/bin/env bash

# this script is to create/delete downtime on nagios for a single host
# using nagios api https://github.com/zorkian/nagios-api


NAGIOS_API_HOST="nagios-staging-1.vpc3.10gen.cc:6315"
log="/tmp/nagios_downtime_schedule.log"

usage()
{
    echo "Usage: $0 -c create -t <duration_in_min> [-m <comment>]"
    echo "Usage: $0 -c delete"
    exit 2
}

chef_client()
{
    case "$1" in
        check)
            timeout=60
            count=0
            while chef_pid=$(pidof chef-client) 2>/dev/null && [ $count -lt $timeout ]; do
                echo "chef-client running at pid $chef_pid, waiting to finish..." >>$log
                count=$((count+1))
                sleep 5
            done
            if [ $count -lt $timeout ]; then
                echo "chef-client not running or completed last run" >>$log
            else
                echo "chef-client has been running for 5min, force kill" >>$log
                [ -d /proc/$chef_pid ] && sudo kill -TERM $chef_pid >>$log 1>&2
            fi
            RETVAL=$?
            return $RETVAL
        ;;
        start|stop)
            sudo /etc/init.d/chef-client "$1"
            RETVAL=$?
            return $RETVAL
        ;;
        default)
            echo "wrong command" 1>&2; exit 2
        ;;
    esac
}

while getopts ":c:h:g:t:m:" opt ; do
    case $opt in
        c) command=$OPTARG ;;
        t) duration_in_min=$OPTARG ;;
        m) comment=$OPTARG ;;
        \?) usage ;;
        :) usage ;;
    esac
done

[ "x$command" == "x" ] && usage

[ -f "$log" ] && rm -f "$log"

host=$(hostname -f)
host=${host:=UNKNOWN}
[ "$host" == "UNKNOWN" ] && { echo "set hostname failed" >>$log; exit 1; }

if [ "$command" == "create" ]; then
    chef_client check || { echo "chef-client is running and cannot be killed, abort" >>$log; exit 1; }

    api="schedule_downtime"
    data="{\"host\": \"$host\","

    [ "$duration_in_min" -eq "$duration_in_min" ] 2>/dev/null || usage
    duration=$(( $duration_in_min * 60 ))

    [ "x$comment" == "x" ] && comment="default comment set by $0"

    data="$data \"duration\": \"$duration\", \"comment\": \"$comment\"}"

    result=$(curl -s -H "Content-Type: application/json" -d "$data" $NAGIOS_API_HOST/$api | sed 's/^{"content": "\(.*\)", "success": \(.*\)}$/\1:\2/')
    [ "$result" != "scheduled:true" ] && { echo "$api failed" >>$log; exit 1; }

    chef_client stop

elif [ "$command" == "delete" ]; then
    api="cancel_downtime"
    data="{\"host\": \"$host\"}"

    result=$(curl -s -H "Content-Type: application/json" -d "$data" $NAGIOS_API_HOST/$api | sed 's/^{"content": "\(.*\)", "success": \(.*\)}$/\1:\2/')
    [ "$result" != "cancelled:true" ] && { echo "$api failed" >>$log; }

    chef_client start
else
    usage
fi

exit $RETVAL
