#!/bin/bash

WORK_DIR="$(dirname "$(realpath "$0")")"

source $WORK_DIR/utils.sh
source $WORK_DIR/slack.sh

DOWNTIME_NULL_RESTART_WAIT_TIME=600
DOWNTIME_BEFORE_RESTART=$DOWNTIME_BEFORE_RESTART
if [[ -z "${DOWNTIME_BEFORE_RESTART}" ]]; then
  DOWNTIME_BEFORE_RESTART=900
fi

APACHE_MONITOR_SLACK_HOOK=$APACHE_MONITOR_SLACK_HOOK
if [ -e "$WORK_DIR/.env" ]; then
  source $WORK_DIR/.env
fi

function restart_successful_handler() {
  text="apache restarted successfully"
  log "${text}"

  if [[ $(string_contains "https://" "$APACHE_MONITOR_SLACK_HOOK") == "1" ]]; then
    slack_notification "$APACHE_MONITOR_SLACK_HOOK" "[$(hostname)]$(date_prefix) $text"
  fi
}

function restart_failed_handler() {
  text="could not restart apache"
  log "$text"

  if [[ $(string_contains "https://" "$APACHE_MONITOR_SLACK_HOOK") == "1" ]]; then
    # multi-line log with contents of `service apache2 status` as a code block below
    text="[$(hostname)]$(date_prefix) $text\n\napache2 status:\n\`\`\` $(service apache2 status) \`\`\`"

    slack_notification "$APACHE_MONITOR_SLACK_HOOK" "$text"
  fi
}

apache2status=$(is_running apache2)
if [[ "$apache2status" == "0" ]]; then
    # apache down, verify downtime

    # retrieving downtime from service status
    apache_status_content=$(service apache2 status)
    if [ $(string_contains "apache2" "$apache_status_content") != "1" ]; then
      # `service apache2 status` returned empty response
      log "apache status empty, exiting"
      exit
    fi

    downdate=$(echo "$apache_status_content" | grep -oP 'since ([a-zA-Z]+) (.*) ([a-zA-Z]+);' | awk '{print $3,$4;}')
    now=$(date "+%F %T")

    # check if downtime available, if not, then wait 10 minutes and try to restart apache
    # waiting 10 minutes to avoid, interrupting ssl update certbot process which requires that apache be down
    if [[ $downdate == "" ]]; then
      log "apache downtime unavailable, waiting 10 minutes before attempting to restart"

      sleep $DOWNTIME_NULL_RESTART_WAIT_TIME

      # check again if apache still down
      if [[ $(is_running apache2) == "0" ]]; then
        # apache still down after 10 minutes
        log "apache is still down after 10 minutes of waiting, attempting to restart..."
        response=$(service apache2 restart &> /dev/null)

        sleep 10

        if [[ $(is_running apache2) == "1" ]]; then
          restart_successful_handler
          exit
        else
          restart_failed_handler
          exit
        fi

      else
        log "apache up on it's own after waiting a bit, no action to take."
        exit
      fi

    fi

    # if here, downtime was retrieved

    now_timestamp=$(date -d "$now" '+%s')
    down_timestamp=$(date -d "$downdate" '+%s')

    downtime=$(( ( $now_timestamp - $down_timestamp ) ))
    downtime_mins=$(($downtime / 60))

    down_text="${downtime_mins} mins"
    if [[ ($downtime_mins < 1) ]]; then
      down_text="${downtime} secs"
    fi

    # if downtime > 15 mins, then restart apache
    if [[ $downtime -gt $DOWNTIME_BEFORE_RESTART ]]; then
      log "apache been down for $down_text, attempting to restart..."
      response=$(service apache2 restart &> /dev/null)

      # wait for 10 seconds before proceeding
      sleep 10

      # check if apache is now up
      if [[ $(is_running apache2) == "1" ]]; then
        # apache is now up
        restart_successful_handler
      else
        # restart did not work, apache still down
        restart_failed_handler
      fi

    else
      # apache been down for less than $DOWNTIME_BEFORE_RESTART (default: 15 mins)
      log "apache has been down only for $down_text, no action taken."
    fi

elif [ "$apache2status" == "null" ]; then
  # `service apache2 status` returned empty response
  log "apache status empty"
fi
