#!/bin/sh

CONFIG=passwall
LOG_FILE=/tmp/log/$CONFIG.log
LOCK_FILE_DIR=/tmp/lock
LOCK_FILE=${LOCK_FILE_DIR}/${CONFIG}_script.lock
sys_lang="$(uci -q get luci.main.lang)"

log_lang() {
	case "$sys_lang" in
		*zh*) echo 1 ;;
		*)    echo 0 ;;
	esac	
}

echolog() {
	local d="$(date "+%Y-%m-%d %H:%M:%S")"
	#echo -e "$d: $1"
	echo -e "$d: $1" >> $LOG_FILE
}

config_n_get() {
	local ret=$(uci -q get "${CONFIG}.${1}.${2}" 2>/dev/null)
	echo "${ret:=$3}"
}

config_t_get() {
	local index=0
	[ -n "$4" ] && index=$4
	local ret=$(uci -q get $CONFIG.@$1[$index].$2 2>/dev/null)
	echo "${ret:=$3}"
}

test_url() {
	local url=$1
	local try=1
	[ -n "$2" ] && try=$2
	local timeout=2
	[ -n "$3" ] && timeout=$3
	local extra_params=$4
	curl --help all | grep "\-\-retry-all-errors" > /dev/null
	[ $? == 0 ] && extra_params="--retry-all-errors ${extra_params}"
	status=$(/usr/bin/curl -I -o /dev/null -skL $extra_params --connect-timeout ${timeout} --retry ${try} -w %{http_code} "$url")
	case "$status" in
		204|\
		200)
			status=200
		;;
	esac
	echo "$status"
}

test_network() {
	local localhost_tcp_proxy_mode=$(config_n_get global localhost_tcp_proxy_mode default)
	case "$localhost_tcp_proxy_mode" in
		"default"|"global"|"gfwlist"|"chnroute")
			#local host proxy is on, test google
			local status=$(test_url "https://www.google.com" ${retry_num} ${connect_timeout})
			if [ "$status" -eq 200 ]; then
				#proxy ok
				echo 0
			else
				#ping AliDNS
				ping -c 3 -W 1 223.5.5.5 > /dev/null 2>&1
				if [ $? -eq 0 ]; then
					#DNS reslove issue
					echo 2
				else
					#network is down
					echo 3
				fi
			fi
		;;
		*)
			#local proxy is off, test baidu
			local status2=$(test_url "https://www.baidu.com" ${retry_num} ${connect_timeout})
			if [ "$status2" -eq 200 ]; then
				echo 1
			else
				#ping AliDNS
				ping -c 3 -W 1 223.5.5.5 > /dev/null 2>&1
				if [ $? -eq 0 ]; then
					#DNS reslove issue
					echo 2
				else
					#network is down
					echo 3
				fi
			fi
		;;
	esac
}

url_test_node() {
	result=0
	local node_id=$1
	local _type=$(echo $(config_n_get ${node_id} type nil) | tr 'A-Z' 'a-z')
	[ "${_type}" != "nil" ] && {
		if [ "${_type}" = "socks" ]; then
			local _address=$(config_n_get ${node_id} address)
			local _port=$(config_n_get ${node_id} port)
			[ -n "${_address}" ] && [ -n "${_port}" ] && {
				local curlx="socks5h://${_address}:${_port}"
				local _username=$(config_n_get ${node_id} username)
				local _password=$(config_n_get ${node_id} password)
				[ -n "${_username}" ] && [ -n "${_password}" ] && curlx="socks5h://${_username}:${_password}@${_address}:${_port}"
			}
		else
			local _tmp_port=$(/usr/share/${CONFIG}/app.sh get_new_port 61080 tcp)
			/usr/share/${CONFIG}/app.sh run_socks flag="url_test_${node_id}" node=${node_id} bind=127.0.0.1 socks_port=${_tmp_port} config_file=url_test_${node_id}.json
			local curlx="socks5h://127.0.0.1:${_tmp_port}"
		fi
		sleep 1s
		result=$(curl --connect-timeout 3 -o /dev/null -I -skL -w "%{http_code}:%{time_starttransfer}" -x $curlx "https://www.google.com/generate_204")
		pgrep -af "url_test_${node_id}" | awk '! /test\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
		rm -rf "/tmp/etc/${CONFIG}/url_test_${node_id}.json"
	}
	echo "$result"
}

test_node() {
	local node_id=$1
	local _type=$(echo $(config_n_get ${node_id} type nil) | tr 'A-Z' 'a-z')
	[ "${_type}" != "nil" ] && {
		if [ "${_type}" = "socks" ]; then
			local _address=$(config_n_get ${node_id} address)
			local _port=$(config_n_get ${node_id} port)
			[ -n "${_address}" ] && [ -n "${_port}" ] && {
				local curlx="socks5h://${_address}:${_port}"
				local _username=$(config_n_get ${node_id} username)
				local _password=$(config_n_get ${node_id} password)
				[ -n "${_username}" ] && [ -n "${_password}" ] && curlx="socks5h://${_username}:${_password}@${_address}:${_port}"
			}
		else
			local _tmp_port=$(/usr/share/${CONFIG}/app.sh get_new_port 61080 tcp)
			/usr/share/${CONFIG}/app.sh run_socks flag="test_node_${node_id}" node=${node_id} bind=127.0.0.1 socks_port=${_tmp_port} config_file=test_node_${node_id}.json
			local curlx="socks5h://127.0.0.1:${_tmp_port}"
		fi
		sleep 1s
		_proxy_status=$(test_url "https://www.google.com/generate_204" ${retry_num} ${connect_timeout} "-x $curlx")
		pgrep -af "test_node_${node_id}" | awk '! /test\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
		rm -rf "/tmp/etc/${CONFIG}/test_node_${node_id}.json"
		if [ "${_proxy_status}" -eq 200 ]; then
			return 0
		fi
	}
	return 1
}

flag=0
main_node=$(config_t_get global tcp_node nil)

test_auto_switch() {
	flag=$(expr $flag + 1)
	local TYPE=$1
	local b_tcp_nodes=$2
	local now_node=$3
	[ -z "$now_node" ] && {
		if [ -f "/tmp/etc/$CONFIG/id/${TYPE}" ]; then
			now_node=$(cat /tmp/etc/$CONFIG/id/${TYPE})
			if [ "$(config_n_get $now_node protocol nil)" = "_shunt" ]; then
				if [ "$shunt_logic" == "1" ] && [ -f "/tmp/etc/$CONFIG/id/${TYPE}_default" ]; then
					now_node=$(cat /tmp/etc/$CONFIG/id/${TYPE}_default)
				elif [ "$shunt_logic" == "2" ] && [ -f "/tmp/etc/$CONFIG/id/${TYPE}_main" ]; then
					now_node=$(cat /tmp/etc/$CONFIG/id/${TYPE}_main)
				else
					shunt_logic=0
				fi
			else
				shunt_logic=0
			fi
		else
			#echolog "自动切换检测：未知错误"
			return 1
		fi
	}
	
	[ $flag -le 1 ] && {
		main_node=$now_node
	}

	status=$(test_network)
	if [ "$status" -eq 0 ]; then
		return 0
	elif [ "$status" -eq 2 ]; then
		if [ "$(log_lang)" -eq 1 ]; then
			echolog "自动切换检测：DNS解析失败，请检查网络是否正常！"
		else
			echolog "Auto switch check: DNS reslove issue, please check network! "
		fi
		#return 2
	elif [ "$status" -eq 3 ]; then
		if [ "$(log_lang)" -eq 1 ]; then
			echolog "自动切换检测：无法连接到网络，请检查网络是否正常！"
		else
			echolog "Auto switch check: no connection, please check network! "
		fi
		return 2
	fi
			
	#检测主节点是否能使用
	if [ "$restore_switch" -eq 1 ] && [ "$main_node" != "nil" ] && [ "$now_node" != "$main_node" ]; then
		test_node ${main_node}
		[ $? -eq 0 ] && {
			#主节点正常，切换到主节点
			if [ "$(log_lang)" -eq 1 ]; then
				echolog "自动切换检测：${TYPE}主节点【$(config_n_get $main_node type)：[$(config_n_get $main_node remarks)]】正常，切换到主节点！"
			else
				echolog "Auto switch check：${TYPE} main node【$(config_n_get $main_node type)：[$(config_n_get $main_node remarks)]】OK，switch back to main node! "
			fi
			/usr/share/${CONFIG}/app.sh node_switch flag=${TYPE} new_node=${main_node} shunt_logic=${shunt_logic}
			[ $? -eq 0 ] && {
				if [ "$(log_lang)" -eq 1 ]; then
					echolog "自动切换检测：${TYPE}节点切换完毕！"
				else
					echolog "Auto switch check：${TYPE} node switch complete! "
				fi
				[ "$shunt_logic" -ne 0 ] && {
					local tcp_node=$(config_t_get global tcp_node nil)
					[ "$(config_n_get $tcp_node protocol nil)" = "_shunt" ] && {
						if [ "$shunt_logic" -eq 1 ]; then
							uci set $CONFIG.$tcp_node.default_node="$main_node"
						elif [ "$shunt_logic" -eq 2 ]; then
							uci set $CONFIG.$tcp_node.main_node="$main_node"
						fi
						uci commit $CONFIG
					}
				}
			}
			return 0
		}
	fi
	
	if [ "$status" -eq 0 ]; then
		#echolog "自动切换检测：${TYPE}节点【$(config_n_get $now_node type)：[$(config_n_get $now_node remarks)]】正常。"
		return 0
	elif [ "$status" -eq 1 ]; then
		if [ "$(log_lang)" -eq 1 ]; then
			echolog "自动切换检测：${TYPE}节点【$(config_n_get $now_node type)：[$(config_n_get $now_node remarks)]】异常，切换到下一个备用节点检测！"
		else
			echolog "Auto switch check：${TYPE} node【$(config_n_get $now_node type)：[$(config_n_get $now_node remarks)]】FAIL，switch to next backup node! "
		fi
		local new_node
		in_backup_nodes=$(echo $b_tcp_nodes | grep $now_node)
		# 判断当前节点是否存在于备用节点列表里
		if [ -z "$in_backup_nodes" ]; then
			# 如果不存在，设置第一个节点为新的节点
			new_node=$(echo $b_tcp_nodes | awk -F ' ' '{print $1}')
		else
			# 如果存在，设置下一个备用节点为新的节点
			#local count=$(expr $(echo $b_tcp_nodes | grep -o ' ' | wc -l) + 1)
			local next_node=$(echo $b_tcp_nodes | awk -F "$now_node" '{print $2}' | awk -F " " '{print $1}')
			if [ -z "$next_node" ]; then
				new_node=$(echo $b_tcp_nodes | awk -F ' ' '{print $1}')
			else
				new_node=$next_node
			fi
		fi
		test_node ${new_node}
		if [ $? -eq 0 ]; then
			# if no restore to main node commit the backup node as main node
			[ "$restore_switch" -eq 0 ] && {
				[ "$shunt_logic" -eq 0 ] && uci -q set $CONFIG.@global[0].tcp_node=$new_node
				[ -z "$(echo $b_tcp_nodes | grep $main_node)" ] && uci -q add_list $CONFIG.@auto_switch[0].tcp_node=$main_node
				uci commit $CONFIG
			}
			if [ "$(log_lang)" -eq 1 ]; then
				echolog "自动切换检测：${TYPE}节点【$(config_n_get $new_node type)：[$(config_n_get $new_node remarks)]】正常，切换到此节点！"
			else
				echolog "Auto switch check：${TYPE} node【$(config_n_get $new_node type)：[$(config_n_get $new_node remarks)]】OK，switch to this node! "
			fi
			/usr/share/${CONFIG}/app.sh node_switch flag=${TYPE} new_node=${new_node} shunt_logic=${shunt_logic}
			[ $? -eq 0 ] && {
				[ "$restore_switch" -eq 1 ] && [ "$shunt_logic" -ne 0 ] && {
					local tcp_node=$(config_t_get global tcp_node nil)
					[ "$(config_n_get $tcp_node protocol nil)" = "_shunt" ] && {
						if [ "$shunt_logic" -eq 1 ]; then
							uci set $CONFIG.$tcp_node.default_node="$main_node"
						elif [ "$shunt_logic" -eq 2 ]; then
							uci set $CONFIG.$tcp_node.main_node="$main_node"
						fi
						uci commit $CONFIG
					}
				}
				if [ "$(log_lang)" -eq 1 ]; then
					echolog "自动切换检测：${TYPE}节点切换完毕！"
				else
					echolog "Auto switch check：${TYPE} node switch complete! "
				fi
			}
			return 0
		else
			# continual if fail
			# try restore action if fail count exceed threshold
			fail_count=$(expr $fail_count + 1)
			[ "$fail_count" -ge "$fail_threshold" ] && {
				restore_connection
				fail_count=0
			}
			test_auto_switch ${TYPE} "${b_tcp_nodes}" ${new_node}
		fi
	fi
# return 1: internal error. return 2: network issue. return 3: failed node switch
}

restore_connection() {
	if [ "$restore_network" -eq 1 ]; then
		case "$restore_action" in
			"quit")
				uci set $CONFIG.@global[0].enabled=0
				uci commit $CONFIG
				if [ "$(log_lang)" -eq 1 ]; then
					echolog "自动修复连接：退出passwall！"
				else
					echolog "Auto connection restore：quit passwall! "
				fi
				/etc/init.d/passwall stop
				return 0
			;;
			"restart")
				if [ "$(log_lang)" -eq 1 ]; then
					echolog "自动修复连接：重启passwall！"
				else
					echolog "Auto connection restore：restart passwall! "
				fi
				/etc/init.d/passwall restart
				return 0
			;;
			"resubscribe")
				local subscribe_proxy=$(config_t_get global_subscribe subscribe_proxy 0)
				if [ "$(log_lang)" -eq 1 ]; then
					echolog "自动修复连接：重新订阅！"
				else
					echolog "Auto connection restore：update subscription! "
				fi
				# if subscribe proxy is enabled, disable it before subscribe
				if [ "$subscribe_proxy" -eq 1 ]; then
					if [ "$(log_lang)" -eq 1 ]; then
						echolog "订阅代理打开，暂时关闭！"
					else
						echolog "Subscription proxy is on, disable temporary! "
					fi
					uci -q set $CONFIG.@global_subscribe[0].subscribe_proxy=0
					/usr/share/${CONFIG}/subscribe.lua start > /dev/null 2>&1
					uci -q revert $CONFIG.@global_subscribe[0].subscribe_proxy
				else
					/usr/share/${CONFIG}/subscribe.lua start > /dev/null 2>&1
				fi
				if [ "$(log_lang)" -eq 1 ]; then
					echolog "自动修复连接：重启passwall！"
				else
					echolog "Auto connection restore：restart passwall! "
				fi
				/etc/init.d/passwall restart
				return 0
			;;
			*)
				return 1
			;;
		esac
	else
		return 0
	fi
}

start() {
	ENABLED=$(config_t_get global enabled 0)
	[ "$ENABLED" != 1 ] && return 1
	ENABLED=$(config_t_get auto_switch enable 0)
	[ "$ENABLED" != 1 ] && return 1
	delay=$(config_t_get auto_switch testing_time 1)
	#sleep 9s
	connect_timeout=$(config_t_get auto_switch connect_timeout 3)
	retry_num=$(config_t_get auto_switch retry_num 3)
	restore_switch=$(config_t_get auto_switch restore_switch 0)
	shunt_logic=$(config_t_get auto_switch shunt_logic 0)
	restore_network=$(config_t_get auto_switch auto_restore 0)
	fail_threshold=$(config_t_get auto_switch fail_threshold 10)
	restore_action=$(config_t_get auto_switch restore_action resubscribe)
	fail_count=0
	
	while [ "$ENABLED" -eq 1 ]; do
		[ -f "$LOCK_FILE" ] && {
			sleep 6s
			continue
		}
		touch $LOCK_FILE
		TCP_NODE=$(config_t_get auto_switch tcp_node nil)
		[ -n "$TCP_NODE" -a "$TCP_NODE" != "nil" ] && {
			TCP_NODE=$(echo $TCP_NODE | tr -s ' ' '\n' | uniq | tr -s '\n' ' ')
			test_auto_switch TCP "$TCP_NODE"
		}
		rm -f $LOCK_FILE
		sleep ${delay}m
	done
}

arg1=$1
shift
case $arg1 in
test_url)
	test_url "$@"
	;;
url_test_node)
	url_test_node "$@"
	;;
*)
	start
	;;
esac
