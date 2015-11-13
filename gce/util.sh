#!/bin/bash

# This script contains helper functions to deploy mesos clusters on GCE.

REDCELL_ROOT=$(pwd)/..
source $REDCELL_ROOT/gce/config-env.sh

ADMIN_PRIVATE_KEY="${HOME}/.ssh/${PROJECT}"

GCLOUD_CMD="gcloud compute"

# Wait for background jobs to finish.
function wait-for-jobs {
    local fail=0
    local job
    for job in $(jobs -p); do
        wait "${job}" || fail=$((fail + 1))
    done
    if (( fail != 0 )); then
        echo -e "\033[0;31m${fail} commands failed.  Exiting.\033[0m" >&2
    fi
}

# Add inventory hosts in a given file
# $1: Path to a file
function add-inventory-hosts {
    local hosts=("${!1}")
    local file=$2
    for i in "${!hosts[@]}"; do
        echo -e "${hosts[$i]}" >> $file
    done
}

# Generate Ansible inventory file for mesos cluster.
function generate-inventory-file {
    local master_external_ips=($($GCLOUD_CMD instances list --regexp="${MESOS_MASTER_NAME}.*" \
            --format=yaml | grep -i natip | sed 's/^ *//' | cut -d ' ' -f 2))
    local master_hostnames=($($GCLOUD_CMD instances list --regexp="${MESOS_MASTER_NAME}.*" \
            --format=yaml | egrep "^name" | cut -d ' ' -f 2))
    local agent_external_ips=($($GCLOUD_CMD instances list --regexp="${MESOS_AGENT_NAME}.*" \
            --format=yaml | grep -i natip | sed 's/^ *//' | cut -d ' ' -f 2))
    local agent_hostnames=($($GCLOUD_CMD instances list --regexp="${MESOS_AGENT_NAME}.*" \
            --format=yaml | egrep "^name" | cut -d ' ' -f 2))
    local agent_attributes=($($GCLOUD_CMD instances list --regexp="${MESOS_AGENT_NAME}.*" \
            --format=yaml | awk '/mesos-agent-attributes/{getline; print}' | sed 's/^ *//' | cut -d ' ' -f 2))

    local inventory_file=$1

    local all_host_vars="cluster_name=$CLOUD"

    echo "# Ansible auto-generated inventory file (cloud: $CLOUD; project: $PROJECT)" > $inventory_file
    echo $'\n'"[all]" >> $inventory_file
    for i in "${!master_external_ips[@]}"; do
        local host_vars="mesos_mode=master mesos_master_quorum=$(((${#master_external_ips[@]}/2)+1)) cluster_name=${CLOUD}-${REGION}"
        echo -e "${master_external_ips[$i]}\t var_hostname=${master_hostnames[$i]} $host_vars" >> $inventory_file
    done
    for i in "${!agent_external_ips[@]}"; do
        mesos_attributes="mesos_attributes=${agent_attributes[$i]};cloud:${CLOUD};level:0"
        weave_network="weave_network=$(IFS=$'\n'; echo "${agent_external_ips[*]}" | head -1)"
        weave_bridge_cidr="weave_bridge_cidr=10.2.0.$(($i+1))/16"

        local host_vars="$weave_bridge_cidr $mesos_attributes cluster_name=${CLOUD}-${REGION}"
        if [[ $i == 0 ]]; then
            echo -e "${agent_external_ips[$i]}\t var_hostname=${agent_hostnames[$i]} mesos_mode=slave $host_vars" >> $inventory_file
        else
            echo -e "${agent_external_ips[$i]}\t var_hostname=${agent_hostnames[$i]} mesos_mode=slave $weave_network $host_vars" >> $inventory_file
        fi
    done

    echo $'\n'"[zookeeper]" >> $inventory_file
    for i in "${!master_external_ips[@]}"; do
        # If a single master is present run zookeeper in standalone mode.
        if [[ "${#master_external_ips[@]}" == 1 ]]; then
            echo -e "${master_external_ips[$i]}\t zookeeper_standalone=true" >> $inventory_file
        else
            echo -e "${master_external_ips[$i]}\t zoo_id=$i" >> $inventory_file
        fi
    done

    echo $'\n'"[mesos]" >> $inventory_file
    add-inventory-hosts master_external_ips[@] $inventory_file
    add-inventory-hosts agent_external_ips[@] $inventory_file

    echo $'\n'"[marathon]" >> $inventory_file
    add-inventory-hosts master_external_ips[@] $inventory_file

    echo $'\n'"[mesos-dns]" >> $inventory_file
    echo $(IFS=$'\n'; echo "${master_external_ips[*]}" | head -1) >> $inventory_file
}

# Create certificate pairs and credentials for the cluster.
function make-certs-and-credentials {
    PKI_TEMP=$(mktemp -d -t pki.XXXXXX)

    local -a ips
    local -a hostnames
    local master_external_ips=($($GCLOUD_CMD instances list \
            --zone="${ZONE}" --regexp="${MESOS_MASTER_NAME}.*" \
            --format=yaml | grep -i natip | sed 's/^ *//' | cut -d ' ' -f 2))
    local master_hostnames=($($GCLOUD_CMD instances list \
            --zone="${ZONE}" --regexp="${MESOS_MASTER_NAME}.*" \
            --format=yaml | egrep "^name" | cut -d ' ' -f 2))

    ips=("${master_external_ips[@]/#/IP:}")
    hostnames=("${master_hostnames[@]/#/DNS:}")
    local -r mesos_sans="$(IFS=$','; echo "${ips[*]}"),$(IFS=$','; echo "${hostnames[*]}")"

    local agent_external_ips=($($GCLOUD_CMD instances list --regexp="${MESOS_AGENT_NAME}.*" \
            --format=yaml | grep -i natip | sed 's/^ *//' | cut -d ' ' -f 2))
    local agent_hostnames=($($GCLOUD_CMD instances list --regexp="${MESOS_AGENT_NAME}.*" \
            --format=yaml | egrep "^name" | cut -d ' ' -f 2))

    ips=("${agent_external_ips[@]/#/IP:}")
    hostnames=("${agent_hostnames[@]/#/DNS:}")
    local -r agent_sans="$(IFS=$','; echo "${ips[*]}"),$(IFS=$','; echo "${hostnames[*]}")"

    (cd $PKI_TEMP
     curl -L -O https://github.com/OpenVPN/easy-rsa/releases/download/3.0.1/EasyRSA-3.0.1.tgz > /dev/null 2>&1
     tar xzf EasyRSA-3.0.1.tgz > /dev/null 2>&1
     cd EasyRSA-3.0.1
    ./easyrsa init-pki
    ./easyrsa --batch build-ca nopass > /dev/null 2>&1
    ./easyrsa --subject-alt-name="${mesos_sans}" build-server-full mesos nopass > /dev/null 2>&1
    ./easyrsa --subject-alt-name="${agent_sans}" build-server-full agent nopass > /dev/null 2>&1
    ./easyrsa --subject-alt-name="${mesos_sans}" build-server-full marathon nopass > /dev/null 2>&1)

    local -a agent_credentials
    for i in "${!agent_hostnames[@]}"; do
        local agent_principal="${agent_hostnames[$i]}"
        local agent_secret=$(python -c 'import string,random; \
      print "".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16))')
        agent_credentials[$i]="$agent_principal $agent_secret"
    done

    CERT_DIR=${PKI_TEMP}/EasyRSA-3.0.1

    local group_vars_dir=$REDCELL_ROOT/ansible/group_vars
    local host_vars_dir=$REDCELL_ROOT/ansible/host_vars

    rm -rf $group_vars_dir && mkdir -p $group_vars_dir
    rm -rf $host_vars_dir && mkdir -p $host_vars_dir
    
    for i in "${!agent_hostnames[@]}"; do
        cat > "$host_vars_dir/${agent_external_ips[$i]}" <<EOF
---
ca_crt: |
$(cat ${CERT_DIR}/pki/ca.crt | sed 's/^/    /')

agent_principal: "$(echo ${agent_credentials[$i]} | cut -d ' ' -f 1)"

agent_secret: "$(echo ${agent_credentials[$i]} | cut -d ' ' -f 2)"

agent_ssl_key: |
$(cat ${CERT_DIR}/pki/private/agent.key | sed 's/^/    /')

agent_ssl_crt: |
$(cat ${CERT_DIR}/pki/issued/agent.crt | sed 's/^/    /')
EOF
    done

    local marathon_principal="mesos-framework-marathon"
    local marathon_secret=$(python -c 'import string,random; \
      print "".join(random.SystemRandom().choice(string.ascii_letters + string.digits) for _ in range(16))')

    cat > $group_vars_dir/marathon <<EOF
---
ca_crt: |
$(cat ${CERT_DIR}/pki/ca.crt | sed 's/^/    /')

marathon_principal: "$marathon_principal"

marathon_secret: "$marathon_secret"

marathon_ssl_key: |
$(cat ${CERT_DIR}/pki/private/marathon.key | sed 's/^/    /')

marathon_ssl_crt: |
$(cat ${CERT_DIR}/pki/issued/marathon.crt | sed 's/^/    /')
EOF

    cat > $group_vars_dir/mesos <<EOF
---
ca_crt: |
$(cat ${CERT_DIR}/pki/ca.crt | sed 's/^/    /')

master_ssl_key: |
$(cat ${CERT_DIR}/pki/private/mesos.key | sed 's/^/    /')

master_ssl_crt: |
$(cat ${CERT_DIR}/pki/issued/mesos.crt | sed 's/^/    /')

mesos_credentials: |
    $marathon_principal $marathon_secret
$(IFS=$'\n'; echo "${agent_credentials[*]}" | sed 's/^/    /')
EOF

    local attempt=0
    while true; do
        if ! ansible-vault encrypt $group_vars_dir/* $host_vars_dir/*; then
            if (( attempt > 4 )); then
                exit 1
            fi
            attempt=$(($attempt+1))
        else
            break
        fi
    done
}

# Create mesos agent template and run instance groups
function create-mesos-agents {
    local mesos_agent_name="${MESOS_AGENT_NAME}-$(basename $1)"
    local mesos_agent_tag="${MESOS_AGENT_TAG}-$(basename $1)"

    source $1

    local mesos_agent_attributes="os:${MESOS_OS_DISTRIBUTION};machine_type:${MESOS_AGENT_TYPE};disk_type:${MESOS_AGENT_DISK_TYPE};zone:${MESOS_AGENT_ZONE}"

    $GCLOUD_CMD firewall-rules create "${mesos_agent_tag}-all" \
                --project "${PROJECT}" \
                --network "${NETWORK}" \
                --source-ranges "${CLUSTER_IP_RANGE}" \
                --target-tags "${mesos_agent_tag}" \
                --allow tcp,udp,icmp,esp,ah,sctp

    local preemptible_agent_args=""
    if [[ "${PREEMPTIBLE_AGENT}" == true ]]; then
        preemptible_agent_args="--preemptible --maintenance-policy TERMINATE"
    fi

    local template_name="${mesos_agent_tag}-template"

    $GCLOUD_CMD instance-templates create "$template_name" \
                --project "${PROJECT}" \
                --machine-type "${MESOS_AGENT_TYPE}" \
                --boot-disk-type "${MESOS_AGENT_DISK_TYPE}" \
                --boot-disk-size "${MESOS_AGENT_DISK_SIZE}" \
                --image "${MESOS_AGENT_IMAGE}" \
                --tags "${mesos_agent_tag}" \
                --metadata-from-file startup-script=configure-instance.sh \
                --metadata "admin-key=$(cat $ADMIN_PRIVATE_KEY.pub),mesos-agent-attributes=${mesos_agent_attributes}" \
                --network "${NETWORK}" \
                $preemptible_agent_args \
                --can-ip-forward >&2

    $GCLOUD_CMD instance-groups managed \
                create "${mesos_agent_tag}-group" \
                --project "${PROJECT}" \
                --zone "${MESOS_AGENT_ZONE}" \
                --base-instance-name "${mesos_agent_tag}" \
                --size "${NUM_CLUSTER_AGENTS}" \
                --template "$template_name" || true;

    $GCLOUD_CMD instance-groups managed wait-until-stable \
                "${mesos_agent_tag}-group" \
                --zone "${MESOS_AGENT_ZONE}" \
                --project "${PROJECT}" || true;
}

# Create a mesos cluster
function mesos-up {
    if ! $GCLOUD_CMD networks --project "${PROJECT}" describe "${NETWORK}" &>/dev/null; then
        echo -e "\033[0;32mCreating new network: ${NETWORK}\033[0m"
        $GCLOUD_CMD networks create --project "${PROJECT}" "${NETWORK}" \
               --range "${CLUSTER_IP_RANGE}"
    fi

    if ! $GCLOUD_CMD firewall-rules --project "${PROJECT}" describe "${NETWORK}-default-internal" &>/dev/null; then
        $GCLOUD_CMD firewall-rules create "${NETWORK}-default-internal" \
               --project "${PROJECT}" \
               --network "${NETWORK}" \
               --source-ranges "10.0.0.0/8" \
               --allow "tcp:1-65535,udp:1-65535,icmp" &
    fi

    if ! $GCLOUD_CMD firewall-rules describe --project "${PROJECT}" "${NETWORK}-default-ssh" &>/dev/null; then
        $GCLOUD_CMD firewall-rules create "${NETWORK}-default-ssh" \
               --project "${PROJECT}" \
               --network "${NETWORK}" \
               --source-ranges "0.0.0.0/0" \
               --allow "tcp:22" &
    fi

    echo -e "\033[0;32mStarting master and configuring firewalls.\033[0m"

    local -a mesos_master_tags
    for i in $(seq 1 $NUM_MESOS_MASTER); do mesos_master_tags[$i]="${MESOS_MASTER_TAG}-$i"; done

    # TODO(rzagabe): The following firewall rule might need to be reviewed.
    $GCLOUD_CMD firewall-rules create "${MESOS_MASTER_TAG}-https" \
           --project "${PROJECT}" \
           --network "${NETWORK}" \
           --target-tags "$(IFS=$','; echo "${mesos_master_tags[*]}")" \
           --allow tcp:443 &

    echo -e "\033[0;32mCreating mesos masters.\033[0m"

    # No instance template/group is created, as static ip addresses
    # will be created and assigned to each one of the master
    # instances. 
    for i in $(seq 1 $NUM_MESOS_MASTER); do
        $GCLOUD_CMD disks create "${mesos_master_tags[$i]}-pd" \
               --project "${PROJECT}" \
               --zone "${ZONE}" \
               --type "${MESOS_MASTER_DISK_TYPE}" \
               --size "${MESOS_MASTER_DISK_SIZE}"

        $GCLOUD_CMD instances create "${mesos_master_tags[$i]}" \
               --project "${PROJECT}" \
               --zone "${ZONE}" \
               --machine-type "${MESOS_MASTER_TYPE}" \
               --image "${MESOS_MASTER_IMAGE}" \
               --tags "${mesos_master_tags[$i]}" \
               --network "${NETWORK}" \
               --can-ip-forward \
               --metadata-from-file startup-script=configure-instance.sh \
               --metadata "admin-key=$(cat $ADMIN_PRIVATE_KEY.pub)" \
               --disk "name=${mesos_master_tags[$i]}-pd,device-name=master-pd,mode=rw,boot=no,auto-delete=no" &
    done

    wait-for-jobs

    # Create all mesos agents with environment file defined inside ./agents
    for file in ./groups/*; do
        echo -e "\033[0;32mCreating mesos agents. Instance group: $(basename $file)\033[0m"
        create-mesos-agents $file
    done

    # Generate Ansible inventory file
    echo -e "\033[0;32mGenerate Ansible inventory file: $PROJECT\033[0m"
    generate-inventory-file $REDCELL_ROOT/ansible/hosts

    echo -e "\033[0;32mGenerate certificates and credentials\033[0m"
    make-certs-and-credentials
    
    sleep 10

    echo -e "\033[0;32mRun Ansible install playbook\033[0m"
    cd $REDCELL_ROOT/ansible
    if ! ansible-playbook -u admin --private-key="${ADMIN_PRIVATE_KEY}" --ask-vault-pass install.yml; then
        echo -e "\033[0;31mAnsible install playbook failed\033[0m"
        echo -e "\033[0;33mThe playbook can be restarted: ./util.sh ansible <ansible paramters>\033[0m"
        exit 1
    fi

    local master_external_ips=($($GCLOUD_CMD instances list \
                                             --zone="${ZONE}" \
                                             --regexp="${MESOS_MASTER_NAME}.*" \
                                             --format=yaml | grep -i natip | sed 's/^ *//' | cut -d ' ' -f 2))
    echo -e "\033[0;32m${PROJECT} cluster is running. The masters are running at:"
    echo
    echo -e "\033[0;33m$(IFS=$'\t'; echo "${master_external_ips[*]}")"
    echo
    echo -e "\033[0;32mThe admin keypair is located in $ADMIN_PRIVATE_KEY\033[0m"
}

# Delete a mesos cluster.
function mesos-down {
    # Create all mesos agents with environment file defined inside ./agents
    for file in ./groups/*; do
        source $file
        
        local mesos_agent_tag="${MESOS_AGENT_TAG}-$(basename $file)"

        # Delete agents group
        if $GCLOUD_CMD instance-groups managed describe "${mesos_agent_tag}-group" --project "${PROJECT}" --zone "${MESOS_AGENT_ZONE}" &>/dev/null; then
            $GCLOUD_CMD instance-groups managed delete --zone "${MESOS_AGENT_ZONE}" \
                        --project "${PROJECT}" \
                        --quiet \
                        "${mesos_agent_tag}-group"
        fi

        # Delete agent instances template
        local template_name="${mesos_agent_tag}-template"
        if $GCLOUD_CMD instance-templates describe --project "${PROJECT}" "$template_name" &>/dev/null; then
            $GCLOUD_CMD instance-templates delete \
                        --project "${PROJECT}" \
                        --quiet \
                        "${template_name}"
        fi

        # Delete agent instances firewall rule
        if $GCLOUD_CMD firewall-rules describe --project "${PROJECT}" "${mesos_agent_tag}-all" &>/dev/null; then
            $GCLOUD_CMD firewall-rules delete  \
                        --project "${PROJECT}" \
                        --quiet \
                        "${mesos_agent_tag}-all"
        fi
    done

    local -a mesos_master_tags
    for node in $(seq 0 $NUM_MESOS_MASTER); do mesos_master_tags[$node]="${MESOS_MASTER_TAG}-$node"; done

    for i in "${!mesos_master_tags[@]}"; do
        # Delete master instances.
        if $GCLOUD_CMD instances describe "${mesos_master_tags[$i]}" --zone "${ZONE}" --project "${PROJECT}" &>/dev/null; then
            $GCLOUD_CMD instances delete \
                   --project "${PROJECT}" \
                   --quiet \
                   --delete-disks all \
                   --zone "${ZONE}" \
                   "${mesos_master_tags[$i]}"
        fi

        # Delete master disks.
        if $GCLOUD_CMD disks describe "${mesos_master_tags[$i]}"-pd --zone "${ZONE}" --project "${PROJECT}" &>/dev/null; then
            $GCLOUD_CMD instances delete \
                   --project "${PROJECT}" \
                   --quiet \
                   --delete-disks all \
                   --zone "${ZONE}" \
                   "${mesos_master_tags[$i]}-pd"
        fi

        # Delete static IP addresses.
        if $GCLOUD_CMD addresses describe "${mesos_master_tags[$i]}-ip" --region "${REGION}" --project "${PROJECT}" &>/dev/null; then
            $GCLOUD_CMD addresses delete \
                   --project "${PROJECT}" \
                   --region "${REGION}" \
                   --quiet \
                   "${mesos_master_tags[$i]}-ip"
        fi
    done

    # Delete master instances firewall rule
    if $GCLOUD_CMD firewall-rules describe --project "${PROJECT}" "${MESOS_MASTER_TAG}-https" &>/dev/null; then
        $GCLOUD_CMD firewall-rules delete  \
               --project "${PROJECT}" \
               --quiet \
               "${MESOS_MASTER_TAG}-https"
    fi

    # Delete all agent instances
    local agents=( $($GCLOUD_CMD instances list --zone="${ZONE}" --regexp="${MESOS_AGENT_NAME}.*" --format=yaml | egrep "^name" | cut -d ' ' -f 2) )
    for i in "${!agents[@]}"; do
        $GCLOUD_CMD instances delete \
               --project "${PROJECT}" \
               --quiet \
               --delete-disks boot \
               --zone "${ZONE}" \
               "${agents[$i]}"
    done

    echo -e "\033[0;32m${PROJECT} cluster is down.\033[0m"
}

opt_usage() {
    print "
GCE cluster deployment utility flags

General options:

run     : Start new mesos cluster
stop    : Shutdown mesos cluster
ansible : Ansible install playbook only
"
}

# determine how we were called, then hand off to the function
# responsible
cmd="$1"
[ -n "$1" ] && shift # scrape off command
case "$cmd" in
    run)
        # Generate admin private key
        ssh-keygen -b 2048 -t rsa -f $ADMIN_PRIVATE_KEY -q -N ""
        mesos-up
        ;;
    stop)
        mesos-down
        ;;
    ansible)
        cd $REDCELL_ROOT/ansible
        ansible-playbook -u admin --private-key="${ADMIN_PRIVATE_KEY}" --ask-vault-pass install.yml ${@:2}
        ;;
    ""|help|-h|--help|--usage)
        opt_usage
        exit 0
        ;;
    *)
        die "Unknown command '$cmd'. Run without commands for usage help."
        ;;
esac
