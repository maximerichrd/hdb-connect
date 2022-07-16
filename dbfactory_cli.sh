#!/usr/bin/env bash

SSH_KEY_PATH="$HOME/.ssh/id_rsa_bastion"
SSH_USER="maxime"
LOCAL_PORT="3308"
FILE="$HOME/bin/dbfactory/dbfactory.conf"

while read -r line; do

  type=${line%=*}

  case "$type" in
    ENV)
    ENVS+=("$(echo -n "$line" | cut -f 2 -d =)") 
    ;;

    DB)
    DATABASES+=("$(echo -n "$line" | cut -f 2 -d =)") 
    ;;
  esac

done < <(grep -e '^ENV' -e '^DB' "${FILE}");  

for env_struct in ${ENVS[@]}; do
  for db in ${DATABASES[@]}; do
    menu="$menu$(echo -n "$db" | cut -f 1 -d :):$(echo -n "$env_struct" | cut -f 1 -d :)\n"
  done
done

choice="$(printf "$menu" | fzf)"

for env_struct in ${ENVS[@]}; do
  chosen_env=${choice##*:}
  env_name=${env_struct%%:*}

  if [ "$env_name" == "$chosen_env" ]; then
    chosen_env_struct="$env_struct"
    break
  fi
done

for db_struct in ${DATABASES[@]}; do
  chosen_db=${choice%%:*}
  db_name=${db_struct%%:*}

  if [ "$db_name" == "$chosen_db" ]; then
    chosen_db_struct="$db_struct"
    break
  fi
done

env=$chosen_env_struct
env_name=$env_name
env_bastion_ip=$(echo -n $env | cut -f 2 -d :)
env_cluster_ip=$(echo -n $env | cut -f 3 -d :)

db=$chosen_db_struct
db_name=$db_name
db_user=$(echo -n $db | cut -f 2 -d :)
db_password=$(echo -n $db | cut -f 3 -d :)

LIGHT_GREEN='\033[1;32m'
NC='\033[0m'

echo -e "${LIGHT_GREEN}Binding ssh db connection to port $LOCAL_PORT ...${NC}"
echo "ssh -i $SSH_KEY_PATH $SSH_USER@$env_bastion_ip -L localhost:$LOCAL_PORT:$env_cluster_ip:3306 -N &"

ssh -i $SSH_KEY_PATH $SSH_USER@$env_bastion_ip -L localhost:$LOCAL_PORT:$env_cluster_ip:3306 -N &
ssh_pid=$!

echo -e "${LIGHT_GREEN}Launching mycli command ...${NC}"
echo "mycli -P $LOCAL_PORT -u $db_user -p ********** $db_name"

mycli -P $LOCAL_PORT -u $db_user -p $db_password -R "\t \d:$env_name> " $db_name

echo -n "Closing ssh db connection..."

kill $ssh_pid
kill_return=$?

if [ $kill_return -ne 0 ]; then
  echo
  echo "The ssh db connection might no be closed, you may run this command to check: " 
  echo 'ps aux | grep ssh' 
  exit 1
else
  echo -e "${LIGHT_GREEN} Done! ${NC}"
  exit 0
fi

