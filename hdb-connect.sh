#!/usr/bin/env bash

WORK_DIR="$(dirname "$0")"
CONFIG_FILE="$WORK_DIR/.env"

# COLORS
OK_COLOR='\033[1;32m'
KO_COLOR='\033[1;36m'
INFO_COLOR='\033[37m'
NO_COLOR='\033[0m'
ok_color() { echo -e "${OK_COLOR}$1${NO_COLOR}"; if [ -n "$2" ]; then echo; fi }
ko_color() { echo -e "${KO_COLOR}$1${NO_COLOR}"; }
info_color() { echo -e "${INFO_COLOR}$1${NO_COLOR}"; if [ -n "$2" ]; then echo; fi }

# MINIMUM FOR OUR RESERVED PORTS
MIN_PORT="33005"

# HELPERS
IP_REGEX="(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
die() { echo "$2" >&2; exit "$1"; }
run() { ( "$@"; ); ret="$?"; (( "$ret" == 0 )) || die 3 "Error while calling '$*' ($ret)" >&2; }
ssm() { run aws ssm get-parameter --name "$1" --output text --query "Parameter.Value" --with-decryption; }
get_ip_from_host() {
  host $1 | grep -E -o "$IP_REGEX" 
}
clean_exit() {
  if [ -z "$1" ]; then
    unset AWS_DEFAULT_PROFILE 
  else
    export AWS_DEFAULT_PROFILE="$1"
  fi
 exit $2;
}
get_ip_from_mysql_config_editor() {
  mysql_config_editor print --login-path="$1" | grep -E -o "$IP_REGEX"  
}
get_port_from_mysql_config_editor() {
  mysql_config_editor print --login-path="$1" | grep -E "port =" | cut -f2 -d'=' | cut -f2 -d' '
}
get_true_database_name_from_mysql_config_editor() {
  mysql_config_editor print --login-path="$1" | grep -E "user =" | cut -f2 -d'=' | cut -f2 -d' ' | cut -f2 -d'"'
}
get_sorted_ports_from_mysql_config_editor() {
  mysql_config_editor print --all | grep -E "port =" | cut -f2 -d'=' | cut -f2 -d' ' | sort -u
}

# SCRIPT START

# GET CONFIG FROM ENV FILE
while read -r line; do

  type=${line%=*}

  case "$type" in
    ENV)
    ENVS+=("$(echo -n "$line" | cut -f2 -d'=')") 
    ;;

    DB)
    DATABASES+=("$(echo -n "$line" | cut -f2 -d'=')") 
    ;;

    BASTION_SSH_PRIV_KEY)
    SSH_PRIV_KEY="$(echo -n "$line" | cut -f2 -d'=')"
    ;;

    BASTION_SSH_USER)
    BASTION_SSH_USER="$(echo -n "$line" | cut -f2 -d'=')"
    ;;

  esac

done < <(grep -e '^ENV' -e '^DB' -e '^BASTION_SSH_PRIV_KEY' -e '^BASTION_SSH_USER' "${CONFIG_FILE}");  

# BUILD MENU
for env_struct in ${ENVS[@]}; do
  for db in ${DATABASES[@]}; do
    menu="$menu$(echo -n "$db" | cut -f1 -d':'):$(echo -n "$env_struct" | cut -f1 -d':')\n"
  done
done

# PRINT MENU TO USER
echo
info_color "> Welcome !"
echo
info_color "> type a name ..."
info_color "> or scroll the list using arrows"
echo
choice="$(printf "$menu" | fzf)"
fzf_ret="$?"

if [ -z $choice ] || [ $fzf_ret -ne 0 ]; then 
  info_color "> Aborting..."
  exit 0
else
  info_color "> $choice" "nl"
fi

# RETRIEVE ENV STRUCT
# FROM USER MENU CHOICE
for env_struct in ${ENVS[@]}; do
  chosen_by_user_env=${choice##*:}
  env_name=${env_struct%%:*}

  if [ "$env_name" == "$chosen_by_user_env" ]; then
    chosen_env_struct="$env_struct"
    break
  fi
done

# RETRIEVE DB STRUCT
# FROM USER MENU CHOICE
for db_struct in ${DATABASES[@]}; do
  chosen_by_user_db=${choice%%:*}
  db_name=${db_struct%%:*}

  if [ "$db_name" == "$chosen_by_user_db" ]; then
    chosen_db_struct="$db_struct"
    break
  fi
done

# NOW GET VALUES FROM STRUCTS
env_name=$(echo -n $chosen_env_struct | cut -f1 -d':')
env_bastion_ip=$(echo -n $chosen_env_struct | cut -f2 -d':')
db_name=$(echo -n $chosen_db_struct | cut -f1 -d':')

# Construct the expected login-path 
# (a login-path is an object entry for mysql_config_editor)
login_path="$db_name""_""$env_name"

# Check in mysql_config_editor if that login_path exists
mysql_config_editor print --login-path=$login_path | grep -q -E $login_path
check_login_path_return="$?"

# If not, call ssm
# and then use an expect script to set up the login_path
if [ $check_login_path_return -ne 0 ]; then
  ok_color "> Setting up $login_path ..."

  # Call aws ssm
  BACK_UP="$AWS_DEFAULT_PROFILE"

  export AWS_DEFAULT_PROFILE="hdb-connect-$env_name"; 

  info_color "calling aws ssm /$env_name/rds/bdd_${db_name}_password ..."
  password=$(run ssm "/$env_name/rds/bdd_${db_name}_password") || clean_exit "$BACK_UP" 3
  ok_color "> ok" "nl"

  info_color "calling aws ssm /$env_name/rds/bdd_${db_name}_username ..."
  user=$(run ssm "/$env_name/rds/bdd_${db_name}_username") || clean_exit "$BACK_UP" 3
  ok_color "> ok" "nl"

  info_color "calling aws ssm /$env_name/rds/bdd_${db_name}_name ..."
  true_database_name=$(run ssm "/$env_name/rds/bdd_${db_name}_name") || clean_exit "$BACK_UP" 3
  ok_color "> ok" "nl"

  info_color "calling aws ssm /$env_name/rds/bdd_${db_name}_rw_host ..."
  rw_db_hostname=$(run ssm "/$env_name/rds/bdd_${db_name}_rw_host") || clean_exit "$BACK_UP" 3
  ok_color "> ok" "nl"

  if [ -z "$BACK_UP" ]; then
    unset AWS_DEFAULT_PROFILE 
  else
    export AWS_DEFAULT_PROFILE="$BACKUP"
  fi

  # translate rw_db_hostname to rw_db_ip
  rw_db_ip=$(run get_ip_from_host "$rw_db_hostname") || exit 3

  # with mysql_config_editor 
  # store rw_ip in a dedicated login-path
  info_color "> writing into $HOME/.mylogin.cnf :"
  run mysql_config_editor set --skip_warn --login-path="${login_path}_metadata" --host="$rw_db_ip" --user="$true_database_name" || exit 3

  echo -ne "${INFO_COLOR}"
  mysql_config_editor print --login-path="${login_path}_metadata"
  echo -ne "${NC}"

  # with mysql_config_editor 
  # store the password and user in a distinct login-path
  # where host is not set to rw_ip but to 127.0.0.1 instead.

  # take care of not reusing one port already stored in mysql_config_editor
  sorted_ports=$(run get_sorted_ports_from_mysql_config_editor) || exit 3
  if [ -z "$sorted_ports" ]; then
    current_highest_port="$MIN_PORT"
  else
    current_highest_port=$(echo "$sorted_ports" | tail -n1)
  fi

  new_port=$((current_highest_port + 1)) 

  # use expect to bypass password stdin input
  run expect -c "
spawn mysql_config_editor set --skip-warn --login-path=$login_path --host=127.0.0.1 --user=$user --port=$new_port --password
expect -nocase \"Enter password:\" {send -- \"$password\r\"; interact}
" > /dev/null 2>&1 

  echo -e "${INFO_COLOR}"
  mysql_config_editor print --login-path="${login_path}"
  echo -e "${NC}"
  ok_color "> ok" "nl"
fi

# Connect into the bastion via a ssh tunnel
# so that we can bind our localhost:$LOCAL_PORT to the $rw_db_ip:3306

rw_db_ip=$(run get_ip_from_mysql_config_editor "${login_path}_metadata") || exit 3
local_port=$(run get_port_from_mysql_config_editor "$login_path") || exit 3

# Avoid binding address already in use
netstat -anp tcp | grep LISTEN | grep -q -E "127.0.0.1.$local_port"
check_if_port_in_use="$?"
if [ $check_if_port_in_use -eq 0 ]; then
  ko_color "> Fatal Error : address 127.0.0.1:$local_port ALREADY IN USE"
  exit 1
fi

# Setup ssh tunnel
ok_color "> Starting ssh tunnel from localhost:$local_port ..."
info_color "> ssh -i $SSH_PRIV_KEY $BASTION_SSH_USER@$env_bastion_ip -L 127.0.0.1:$local_port:$rw_db_ip:3306 -f sleep 10 &" "nl"

ssh -i $SSH_PRIV_KEY $BASTION_SSH_USER@$env_bastion_ip -L 127.0.0.1:$local_port:$rw_db_ip:3306 -f sleep 10 &
ssh_pid=$!
sleep 1

# Launch mycli
true_database_name=$(run get_true_database_name_from_mysql_config_editor ${login_path}_metadata) || exit 3

ok_color "> Connecting to $login_path ..."
info_color "> mycli --login-path $login_path $true_database_name" "nl"

mycli --login-path $login_path --prompt "\t \d:$env_name> " $true_database_name

# Gracefully exit
if ps -p "$ssh_pid" > /dev/null
then
   kill $ssh_pid > /dev/null 2>&1
fi

echo
info_color "> Bye !" "nl"
