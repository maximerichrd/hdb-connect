#!/usr/bin/env bash

# have a $HOME/.aws/credentials file with following profiles :
# [hfactory-db-connect-dev]
# [hfactory-db-connect-test]
# [hfactory-db-connect-itg]
# [hfactory-db-connect-ppd]

die() { echo "$2" >&2; exit "$1"; }
run() { ( set -x; "$@"; ); ret="$?"; (( "$ret" == 0 )) || die 3 "Error while calling '$*' ($ret)" >&2; }
ssm() { AWS_DEFAULT_PROFILE="$2" && run aws ssm get-parameter --name "$1" --output text --query "Parameter.Value" --with-decryption; }
get_ip_from_host() {
  host $1 | grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
}

TEST_HOST=$(ssm "/dev/rds/bdd_mscbr_ame_rw_host" "hfactory-db-connect-dev")

IP=$(run get_ip_from_host $TEST_HOST)

echo $IP



