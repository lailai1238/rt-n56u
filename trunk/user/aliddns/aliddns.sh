#!/bin/sh
#copyright by xRetia Labs
#source /etc/storage/init.sh
#ACTION=$1
export PATH='/etc/storage/bin:/tmp/script:/etc/storage/script:/opt/usr/sbin:/opt/usr/bin:/opt/sbin:/opt/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin'
export LD_LIBRARY_PATH=/lib:/opt/lib
ACTION=$1
scriptfilepath=$(
	cd "$(dirname "$0")"
	pwd
)/$(basename $0)
#echo $scriptfilepath
scriptpath=$(
	cd "$(dirname "$0")"
	pwd
)
#echo $scriptpath
scriptname=$(basename $0)

aliddns_enable=$(nvram get aliddns_enable)
[ -z $aliddns_enable ] && aliddns_enable=0 && nvram set aliddns_enable=0
if [ "$aliddns_enable" == "0" ]; then
	exit
fi

aliddns_interval=$(nvram get aliddns_interval)
aliddns_ak=$(nvram get aliddns_ak)
aliddns_sk=$(nvram get aliddns_sk)
aliddns_domain=$(nvram get aliddns_domain)
aliddns_name=$(nvram get aliddns_name)
aliddns_domain2=$(nvram get aliddns_domain2)
aliddns_name2=$(nvram get aliddns_name2)
aliddns_domain6=$(nvram get aliddns_domain6)
aliddns_name6=$(nvram get aliddns_name6)
aliddns_ttl=$(nvram get aliddns_ttl)

if [ "$aliddns_domain"x != "x" ] && [ "$aliddns_name"x = "x" ]; then
    aliddns_name="www"
    nvram set aliddns_name="www"
fi

API_TOKEN=$aliddns_ak                       # Your API Token
ZONE_ID=$aliddns_sk                         # Your zone id, hex16 string
RECORD_NAME="$aliddns_name.$aliddns_domain" # Your DNS record name, e.g. sub.example.com
RECORD_TTL=$aliddns_ttl                     # TTL in seconds (1=auto)
UPDATE_IPv6=true                            # Set to true if you want to also update IPv6
IP_QUERY_SITE="http://ip.sb/" # Site used to get external DNS if router isn't able to pull it due to double NAT

get_dns_record_ids() {
    local record_name=$1
    local type=$2
    local api_token=$3
    local zone_id=$4

    RESPONSE="$(
        curl -sk -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=${type}&name=${record_name}" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type:application/json"
    )"

    echo $RESPONSE | grep -oEe '"id":"[a-f0-9]{32}' | grep -oEe '[a-f0-9]{32}'
}

update_dns_record() {
    local record_name=$1
    local record_id=$2
    local type=$3
    local ip=$4
    local record_ttl=$5
    local api_token=$6
    local zone_id=$7

    curl -sk -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${api_token}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"${type}\",\"name\":\"${record_name}\",\"content\":\"${ip}\",\"ttl\":${record_ttl},\"proxied\":false}"
}

aliddns_start() {
    RESULT=true
    IPv4="$(curl -kfs4 $IP_QUERY_SITE)"
    IPv6=$(ip -6 addr list scope global $device | grep -v " fd" | sed -n 's/.*inet6 \([0-9a-f:]\+\).*/\1/p' | head -n 1)
    
    # Check Need Update?
    Check_V4=$(nslookup $RECORD_NAME | grep -c "$IPv4")
    Check_V6=$(nslookup $RECORD_NAME | grep -c "$IPv6")
    if [ "$IPv4" != "" ] && [ "$Check_V4" != "0" ]
    then
        Check_V4="SAME_V4"
    fi
    if [ "$IPv6" != "" ]; then
        if [ "$Check_V4" != "0" ]; then
            Check_V6="SAME_V6"
        fi
    else
        Check_V6="SAME_V6"
    fi
    if [ "$Check_V4" == "SAME_V4" ] && [ "$Check_V6" == "SAME_V6" ]
    then
        return 0
    fi
    
    # Update IPv4
    #Get IPv4 from Router otherwise from external source
    logger -t "CloudFlare 动态域名" "IP ${IPv4} obtained external source $IP_QUERY_SITE"
    A_RECORD_IDS=$(get_dns_record_ids $RECORD_NAME A $API_TOKEN $ZONE_ID)

    for A_RECORD_ID in $A_RECORD_IDS; do
        RESPONSE="$(update_dns_record $RECORD_NAME $A_RECORD_ID A $IPv4 $RECORD_TTL $API_TOKEN $ZONE_ID)"
        echo $RESPONSE | grep '"success":\ *true' >/dev/null

        if [ $? -eq 0 ]; then
            logger -t "CloudFlare 动态域名" "Updated A record for ${RECORD_NAME} to ${IPv4}"
        else
            logger -t "CloudFlare 动态域名" "Unable to update A record for ${RECORD_NAME} with ${IPv4}"
            RESULT=false
        fi
    done

    if [ "$UPDATE_IPv6" == true ]; then
        # Update IPv6
        if [ "$IPv6" != "" ]; then
            AAAA_RECORD_IDS=$(get_dns_record_ids $RECORD_NAME AAAA $API_TOKEN $ZONE_ID)
            for AAAA_RECORD_ID in $AAAA_RECORD_IDS; do
                RESPONSE="$(update_dns_record $RECORD_NAME $AAAA_RECORD_ID AAAA $IPv6 $RECORD_TTL $API_TOKEN $ZONE_ID)"
                echo $RESPONSE | grep '"success":\ *true' >/dev/null

                if [ $? -eq 0 ]; then
                    logger -t "CloudFlare 动态域名" "Updated AAAA record for ${RECORD_NAME} to ${IPv6}"
                else
                    logger -t "CloudFlare 动态域名" "Unable to update AAAA record for ${RECORD_NAME}"
                    RESULT=false
                fi
            done
        fi
    fi

    if [ "$RESULT" == true ]; then
        nvram set aliddns_last_act="`date "+%Y-%m-%d %H:%M:%S"`   成功更新"
        logger -t "CloudFlare 动态域名" "成功更新"
        return 0
    else
        nvram set aliddns_last_act="`date "+%Y-%m-%d %H:%M:%S"`   更新失败"
        logger -t "CloudFlare 动态域名" "更新失败"
        return 1
    fi
}


aliddns_keep() {
	aliddns_start
	logger -t "CloudFlare 动态域名" "守护进程启动"
	while true; do
		sleep $aliddns_interval
		[ ! -s "$(which curl)" ] && aliddns_restart
		#nvramshow=`nvram showall | grep '=' | grep aliddns | awk '{print gensub(/'"'"'/,"'"'"'\"'"'"'\"'"'"'","g",$0);}'| awk '{print gensub(/=/,"='\''",1,$0)"'\'';";}'` && eval $nvramshow
		aliddns_enable=$(nvram get aliddns_enable)
		[ "$aliddns_enable" = "0" ] && aliddns_close && exit 0
		if [ "$aliddns_enable" = "1" ]; then
			aliddns_start
		fi
	done
}

kill_ps () {
    COMMAND="$1"
    if [ ! -z "$COMMAND" ] ; then
        eval $(ps -w | grep "$COMMAND" | grep -v $$ | grep -v grep | awk '{print "kill "$1";";}')
        eval $(ps -w | grep "$COMMAND" | grep -v $$ | grep -v grep | awk '{print "kill -9 "$1";";}')
    fi
    if [ "$2" == "exit0" ] ; then
        exit 0
    fi
}

aliddns_close () {
    kill_ps "/tmp/script/_aliddns"
    kill_ps "_aliddns.sh"
    kill_ps "aliddns.sh"
    kill_ps "$scriptname"
}

aliddns_restart() {
	relock="/var/lock/aliddns_restart.lock"
	if [ "$1" = "o" ]; then
		nvram set aliddns_renum="0"
		[ -f $relock ] && rm -f $relock
		return 0
	fi
	if [ "$1" = "x" ]; then
		if [ -f $relock ]; then
			logger -t "CloudFlare 动态域名" "多次尝试启动失败，等待【"$(cat $relock)"分钟】后自动尝试重新启动"
			exit 0
		fi
		aliddns_renum=${aliddns_renum:-"0"}
		aliddns_renum=$(expr $aliddns_renum + 1)
		nvram set aliddns_renum="$aliddns_renum"
		if [ "$aliddns_renum" -gt "2" ]; then
			I=19
			echo $I >$relock
			logger -t "CloudFlare 动态域名" "多次尝试启动失败，等待【"$(cat $relock)"分钟】后自动尝试重新启动"
			while [ $I -gt 0 ]; do
				I=$(($I - 1))
				echo $I >$relock
				sleep 60
				[ "$(nvram get aliddns_renum)" = "0" ] && exit 0
				[ $I -lt 0 ] && break
			done
			nvram set aliddns_renum="0"
		fi
		[ -f $relock ] && rm -f $relock
	fi
	nvram set aliddns_status=0
	eval "$scriptfilepath &"
	exit 0
}

aliddns_get_status() {
	A_restart=$(nvram get aliddns_status)
	B_restart="$aliddns_enable$aliddns_interval$aliddns_ak$aliddns_sk$aliddns_domain$aliddns_name$aliddns_domain2$aliddns_name2$aliddns_domain6$aliddns_name6$aliddns_ttl$(cat /etc/storage/ddns_script.sh | grep -v '^#' | grep -v "^$")"
	B_restart=$(echo -n "$B_restart" | md5sum | sed s/[[:space:]]//g | sed s/-//g)
	if [ "$A_restart" != "$B_restart" ]; then
		nvram set aliddns_status=$B_restart
		needed_restart=1
	else
		needed_restart=0
	fi
}

aliddns_check() {
	aliddns_get_status
	if [ "$aliddns_enable" != "1" ] && [ "$needed_restart" = "1" ]; then
		[ ! -z "$(ps -w | grep "$scriptname keep" | grep -v grep)" ] && logger -t "CloudFlare 动态域名" "停止 CloudFlare 动态域名" && aliddns_close
		{
			kill_ps "$scriptname" exit0
			exit 0
		}
	fi
	if [ "$aliddns_enable" = "1" ]; then
		if [ "$needed_restart" = "1" ]; then
			aliddns_close
			eval "$scriptfilepath keep &"
			exit 0
		else
			[ -z "$(ps -w | grep "$scriptname keep" | grep -v grep)" ] || [ ! -s "$(which curl)" ] && aliddns_restart
		fi
	fi
}


case $ACTION in
start)
	aliddns_close
	aliddns_check
	;;
check)
	aliddns_check
	;;
stop)
	aliddns_close
	;;
keep)
	aliddns_keep
	;;
*)
	aliddns_check
	;;
esac
