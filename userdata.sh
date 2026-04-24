#!/bin/bash -e
# Custom user-data for pre-built AMI
# Skips: dnf upgrade-minimal, docker install, runner binary download
# Only does: symlink setup + runner start/registration

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
set -x

# Map /opt/actions-runner to /home/fedora
RUNNER_USER="fedora"
HOME_DIR="/home/$RUNNER_USER"
TARGET_DIR="$HOME_DIR/actions-runner"
mkdir -p $TARGET_DIR

# Move pre-installed runner files to home directory
if [ -d /opt/actions-runner/bin ]; then
  cp -a /opt/actions-runner/* $TARGET_DIR/ 2>/dev/null || true
  cp -a /opt/actions-runner/.* $TARGET_DIR/ 2>/dev/null || true
  rm -rf /opt/actions-runner
fi

ln -s $TARGET_DIR /opt/actions-runner
chown -R $RUNNER_USER:$RUNNER_USER $TARGET_DIR /opt/hostedtoolcache
chown -h $RUNNER_USER:$RUNNER_USER /opt/actions-runner

# Allow systemd and containers to traverse home directory
chmod 755 $HOME_DIR

# Fix SELinux context so systemd can execute runner from home directory via symlink
chcon -R -t bin_t $TARGET_DIR/bin $TARGET_DIR/runsvc.sh $TARGET_DIR/run.sh $TARGET_DIR/run-helper.sh.template $TARGET_DIR/config.sh $TARGET_DIR/env.sh $TARGET_DIR/safe_sleep.sh $TARGET_DIR/svc.sh 2>/dev/null || true
restorecon -R /opt/actions-runner 2>/dev/null || true

user_name=ec2-user
chown -R "$user_name":"$user_name" /opt/actions-runner
chown -R "$user_name":"$user_name" /opt/hostedtoolcache

## ---- start-runner logic (from module template, resolved for our config) ----

cleanup() {
  local exit_code="$1"
  local error_location="$2"
  local error_lineno="$3"

  if [ "$exit_code" -ne 0 ]; then
    echo "ERROR: runner-start-failed with exit code $exit_code occurred on $error_location"
  fi
  sleep 10
  if [ "$agent_mode" = "ephemeral" ] || [ "$exit_code" -ne 0 ]; then
    echo "Terminating instance"
    aws ec2 terminate-instances \
      --instance-ids "$instance_id" \
      --region "$region" \
      || true
  fi
}

trap 'cleanup $? $LINENO $BASH_LINENO' EXIT

echo "Retrieving TOKEN from AWS API"
token=$(curl -f -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 180" || true)
if [ -z "$token" ]; then
  retrycount=0
  until [ -n "$token" ]; do
    echo "Failed to retrieve token. Retrying in 5 seconds."
    sleep 5
    token=$(curl -f -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 180" || true)
    retrycount=$((retrycount + 1))
    if [ $retrycount -gt 40 ]; then
      break
    fi
  done
fi

ami_id=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/ami-id)
region=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
echo "Retrieved REGION from AWS API ($region)"

instance_id=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/instance-id)
echo "Retrieved INSTANCE_ID from AWS API ($instance_id)"

instance_type=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/instance-type)
availability_zone=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/placement/availability-zone)

environment=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/tags/instance/ghr:environment)
ssm_config_path=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/tags/instance/ghr:ssm_config_path)
runner_name_prefix=$(curl -f -H "X-aws-ec2-metadata-token: $token" -v http://169.254.169.254/latest/meta-data/tags/instance/ghr:runner_name_prefix || echo "")

echo "Retrieved ghr:environment tag - ($environment)"
echo "Retrieved ghr:ssm_config_path tag - ($ssm_config_path)"
echo "Retrieved ghr:runner_name_prefix tag - ($runner_name_prefix)"

parameters=$(aws ssm get-parameters-by-path --path "$ssm_config_path" --region "$region" --query "Parameters[*].{Name:Name,Value:Value}")
echo "Retrieved parameters from AWS SSM ($parameters)"

run_as=$(echo "$parameters" | jq -r '.[] | select(.Name == "'$ssm_config_path'/run_as") | .Value')
echo "Retrieved /$ssm_config_path/run_as parameter - ($run_as)"

agent_mode=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/agent_mode") | .Value')
echo "Retrieved /$ssm_config_path/agent_mode parameter - ($agent_mode)"

enable_jit_config=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/enable_jit_config") | .Value')
echo "Retrieved /$ssm_config_path/enable_jit_config parameter - ($enable_jit_config)"

token_path=$(echo "$parameters" | jq --arg ssm_config_path "$ssm_config_path" -r '.[] | select(.Name == "'$ssm_config_path'/token_path") | .Value')
echo "Retrieved /$ssm_config_path/token_path parameter - ($token_path)"

## Configure the runner

echo "Get GH Runner config from AWS SSM"
config=$(aws ssm get-parameter --name "$token_path"/"$instance_id" --with-decryption --region "$region" | jq -r ".Parameter | .Value")
while [[ -z "$config" ]]; do
  echo "Waiting for GH Runner config to become available in AWS SSM"
  sleep 1
  config=$(aws ssm get-parameter --name "$token_path"/"$instance_id" --with-decryption --region "$region" | jq -r ".Parameter | .Value")
done

echo "Delete GH Runner token from AWS SSM"
aws ssm delete-parameter --name "$token_path"/"$instance_id" --region "$region"

if [ -z "$run_as" ]; then
  echo "No user specified, using default ec2-user account"
  run_as="ec2-user"
fi

if [[ "$run_as" == "root" ]]; then
  export RUNNER_ALLOW_RUNASROOT=1
fi

chown -R $run_as /opt/actions-runner

info_arch=$(uname -p)
info_os=$( ( lsb_release -ds || cat /etc/*release || uname -om ) 2>/dev/null | head -n1 | cut -d "=" -f2- | tr -d '"')

tee /opt/actions-runner/.setup_info <<EOL
[
  {
    "group": "Operating System",
    "detail": "Distribution: $info_os\nArchitecture: $info_arch"
  },
  {
    "group": "Runner Image",
    "detail": "AMI id: $ami_id"
  },
  {
    "group": "EC2",
    "detail": "Instance type: $instance_type\nAvailability zone: $availability_zone"
  }
]
EOL

## Install job hooks for cleanup between jobs
echo "Installing job hooks..."
cat > /opt/actions-runner/hook_job_started.sh <<'HOOKEOF'
#!/bin/bash

sudo buildah rm --all
sudo podman rmi --all --force
sudo podman system reset --force

echo "Cleaning up registry authorization tokens..."
sudo find /root -name 'crucible-*-engines-token.json' -print -delete
sudo find /root -name 'quay-oauth.token' -print -delete
echo "...cleanup complete"

echo "Cleaning up SSH key..."
sudo rm -fv /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub
echo "...cleanup complete"

toolbox_logged_die_filename="/tmp/toolbox_logged_die.txt"
if [ -e "${toolbox_logged_die_filename}" ]; then
    echo "Found ${toolbox_logged_die_filename}"
    rm -v ${toolbox_logged_die_filename}
fi

# cleanup the workspace
if [ -n "${GITHUB_WORKSPACE}" ]; then
    if pushd "${GITHUB_WORKSPACE}"; then
	echo "Cleaning up..."
	sudo find ! -name '.' ! -name '..' -delete
	echo "...cleanup complete"

	popd
    else
	echo "ERROR: Failed to pushd to '${GITHUB_WORKSPACE}'"
	exit 1
    fi
else
    echo "ERROR: GITHUB_WORKSPACE is not defined"
    exit 1
fi
HOOKEOF

chmod +x /opt/actions-runner/hook_job_started.sh
cp /opt/actions-runner/hook_job_started.sh /opt/actions-runner/hook_job_completed.sh

echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hook_job_started.sh" >> /opt/actions-runner/.env
echo "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/actions-runner/hook_job_completed.sh" >> /opt/actions-runner/.env
echo "Job hooks installed"

## Start the runner
echo "Starting runner after $(awk '{print int($1/3600)":"int(($1%3600)/60)":"int($1%60)}' /proc/uptime)"
echo "Starting the runner as user $run_as"

cd /opt/actions-runner

if [[ "$enable_jit_config" == "false" || $agent_mode != "ephemeral" ]]; then
  echo "Configure GH Runner as user $run_as"
  sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./config.sh --unattended --name "$runner_name_prefix$instance_id" --work "_work" ${config}
fi

if [[ $agent_mode = "ephemeral" ]]; then
  echo "Starting the runner in ephemeral mode"
  if [[ "$enable_jit_config" == "true" ]]; then
    echo "Starting with JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh --jitconfig ${config}
  else
    echo "Starting without JIT config"
    sudo --preserve-env=RUNNER_ALLOW_RUNASROOT -u "$run_as" -- ./run.sh
  fi
  echo "Runner has finished"
else
  echo "Installing the runner as a service"
  ./svc.sh install "$run_as"
  # Fix SELinux context on runsvc.sh (created by svc.sh install) so systemd can execute it via symlink
  chcon -t bin_t /opt/actions-runner/runsvc.sh 2>/dev/null || true
  echo "Starting the runner in persistent mode"
  ./svc.sh start
fi
