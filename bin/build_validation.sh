#!/usr/bin/env bash 


source $HOME/.bashrc



TEMP=$(getopt -o h --long "help,no-clients,vagrant-box:,vagrantfile:,ses-only,destroy,all-scripts,only-script:,existing,only-salt-cluster,destroy-before-deploy,sle-slp-dir:,ses-slp-dir:,ses-ibs-dir:" -n 'build_validation.sh' -- "$@")


if [ $? -ne 0 ]; then echo "Terminating ..." >&2; exit 1; fi

export PDSH_SSH_ARGS_APPEND="-i ~/.ssh/storage-automation -l root -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ses_only=false
destroy=false
all_scripts=false
only_script=false
existing=false
only_salt_cluster=false
destroy_b4_deploy=false
no_clients=false

function helpme () {
  cat << EOF

  usage: ./build_validation.sh --help
  build_validation.sh [arguments]

  arguments:
    --vagrantfile            VAGRANTFILE
    --ses-only               deploys only SES without running BV test scripts
    --destroy                destroys project (vagrant destroy -f)
    --all-scripts            runs all BV scripts under ./scripts directory
    --only-script            runs only specified script
    --existing               runs BV scripts on existing cluster
    --only-salt-cluster      deploys cluster with salt
    --vagrant-box            existing vagrant box name. Don't use with option --sle-slp-dir. 
    --sle-slp-dir            directory of SLE Full SLP (example: SLE-15-SP2-Full-Snapshot16)
    --ses-slp-dir            directory of SES SLP (example: SUSE-Enterprise-Storage-7-Milestone11)
    --ses-ibs-dir            directory of SES ibs (example: SUSE-Enterprise-Storage-7-POOL-x86_64-Media1)
    --destroy-before-deploy  destroys existing cluster before deployment (useful for Jenkins)
    --no-clients             scripts for testing of the clients will not be executed

EOF
}

eval set -- "$TEMP"

while true
do
    case $1 in
        --vagrantfile) export VAGRANT_VAGRANTFILE=$2; shift 2;;
        --ses-only) ses_only=true; shift;;
        --destroy) destroy=true; shift;;
        --all-scripts) all_scripts=true; shift;;
        --only-script) only_script=true; one_script+=($2); shift 2;;
        --existing) existing=true; shift;;
        --only-salt-cluster) only_salt_cluster=true; shift;;
        --vagrant-box) vagrant_box=$2; shift 2;;
        --destroy-before-deploy) destroy_b4_deploy=true; shift;;
        --sle-slp-dir) sle_slp_dir=$2 
                       sle_url="http://download.suse.de/install/SLP/$sle_slp_dir/$(arch)/DVD1"
                       shift 2;;
        --ses-slp-dir) ses_slp_dir=$2
                       ses_url="http://download.suse.de/install/SLP/$ses_slp_dir/$(arch)/DVD1"
                       shift 2;;
        --ses-ibs-dir) ses_slp_dir=$2
                       ses_url="http://download.suse.de/ibs/Devel:/Storage:/7.0/images/repo/$ses_slp_dir"
                       shift 2;;
        --no-clients) no_clients=true; shift;;
        --help|-h) helpme; exit;;
        --) shift; break;;
        *) break;;
    esac
done

if [ -z "$VAGRANT_VAGRANTFILE" ]
then
    echo "Missing VAGRANTFILE"
    exit 1
fi

if [ -z "$VAGRANT_HOME" ]
then
    echo "variable VAGRANT_HOME not set"
    exit 1
fi

if [ ! -f "$HOME/.ssh/storage-automation" ]
then
    echo "Missing file $HOME/.ssh/storage-automation"
    exit 1
fi

sudo --validate
if [ $? -ne 0 ]
then
    echo "user $USER has not sudo privilegies"
    exit 1
fi

if [ -d "logs" ] && [ "$(ls -A logs 2>/dev/null)" ];then
    archive_name="logs_$(date +%F-%H-%M).txz"
    echo "creating archive $archive_name from existing logs"
    tar cJf $archive_name logs --remove-files
fi

mkdir logs 2>/dev/null

function vssh_script () {
    local node=$1
    local script="$2"
    echo "WWWWW $script WWWWW"
    pdsh -S -l root -w $node "find /var/log -type f -exec truncate -s 0 {} \;"
    if [ "$script" == "deploy_ses.sh" ]; then
        pdsh -S -l root -w $node "bash /scripts/$script"
    else
        pdsh -S -l root -w $node "timeout -s SIGKILL 1h bash /scripts/$script"
    fi
    script_exit_value=$?
}

function create_snapshot () {
    local nodes="$1"
    local script="$2"
    local ses_cluster="$(echo ${ses_cluster[@]})"
    if [ $script_exit_value -ne 0 ] || [ "$script" == "deployment" ]
    then
        echo
        echo "Collecting supportconfig files"
        echo
        pdsh -S -l root -w ${ses_cluster// /,} "supportconfig" >/dev/null 2>&1
        mkdir -p logs/${script%%.*} 2>/dev/null
        rpdcp -l root -w ${ses_cluster// /,} /var/log/scc_* logs/${script%%.*}/
        pdsh -l root -w ${ses_cluster// /,} "rm -rf /var/log/scc_*"
        for node in $nodes
        do
            sudo virsh destroy ${project}_${node}
            if [ "$(arch)" == "aarch64" ];then
                sed -i '/pflash/d; /acpi/d; /apic/d' /etc/libvirt/qemu/${project}_${node}.xml
            fi
        done
         
        if [ "$(arch)" == "aarch64" ];then
            sudo systemctl restart libvirtd
        fi

        for node in $nodes
        do
            sudo virsh snapshot-create-as ${project}_${node} ${script%%.*}
        done
        if [ "$(arch)" == "aarch64" ];then
            rsync -aP /etc/libvirt/qemu_pflash/ /etc/libvirt/qemu/
            sudo systemctl restart libvirtd
        fi

    fi
}

function revert_to_ses () {
    echo "Reverting cluster to snapshot \"deployment\""
    for node in ${ses_cluster[@]%%.*}
    do
        node="${project}_${node}"
        sudo virsh snapshot-revert $node deployment >/dev/null 2>&1
    done

    if [ "$(arch)" == "aarch64" ];then
        rsync -aP /etc/libvirt/qemu_pflash/ /etc/libvirt/qemu/
        sudo systemctl restart libvirtd
    fi

    for node in ${ses_cluster[@]%%.*}
    do
        node="${project}_${node}"
        sudo virsh start $node
    done

    sleep 30
}

function wait_for_health_ok () {
    while [ "$(ssh $ssh_options ${monitors[0]%%.*} "ceph health" 2>/dev/null)" != "HEALTH_OK" ]
    do
        sleep 30
    done
}

function set_variables () {
source ${VAGRANT_VAGRANTFILE}-files/bashrc
monitors=($monitors)
osd_nodes=($osd_nodes)
ses_cluster=(${master} ${monitors[@]} ${osd_nodes[@]})
}

function metadata_json () {
cat << EOF >> $VAGRANT_HOME/boxes/$vagrant_box/0/libvirt/metadata.json
{
  "provider"     : "libvirt",
  "format"       : "qcow2",
  "virtual_size" : 10
}
EOF
}

function vgrvagrantfile () {
cat << EOF >> $VAGRANT_HOME/boxes/$vagrant_box/0/libvirt/Vagrantfile
Vagrant.configure("2") do |config|
         config.vm.provider :libvirt do |libvirt|
         libvirt.driver = "kvm"
         libvirt.host = 'localhost'
         libvirt.uri = 'qemu:///system'
         end
config.vm.define "new" do |custombox|
         custombox.vm.box = "custombox"
         custombox.vm.provider :libvirt do |test|
         test.memory = 1024
         test.cpus = 1
         end
         end
end
EOF
}

function destroy_existing_cluster () {
    nodes_list=($(vagrant status | awk '/libvirt/{print $1}'))
    sudo virsh list --all --name | grep ${project}_ | xargs -I {} sudo virsh destroy {}
    sudo bash -c "rm -f ${qemu_default_pool}/${project}_*"
    sudo systemctl restart libvirtd
    for node in ${nodes_list[@]}
    do
        for snap in $(sudo virsh snapshot-list --name ${project}_${node})
        do
            sudo virsh snapshot-delete ${project}_${node} $snap
        done
    done

    if [ "$(arch)" == "aarch64" ];then
        sudo virsh list --all --name | grep ${project}_ | xargs -I {} sudo virsh undefine {} --nvram
    else
        sudo virsh list --all --name | grep ${project}_ | xargs -I {} sudo virsh undefine {}
    fi

    vagrant destroy -f
}

ses_deploy_scripts=(deploy_ses.sh hosts_file_correction.sh configure_ses.sh)
project=$(basename $PWD)
if $no_clients; then
    scripts=$(find scripts/ -maxdepth 1 -type f ! -name ${ses_deploy_scripts[0]} \
         -and ! -name ${ses_deploy_scripts[1]} -and ! -name ${ses_deploy_scripts[2]} \
         -and ! -name clients_\* -exec basename {} \;)
else
    scripts=$(find scripts/ -maxdepth 1 -type f ! -name ${ses_deploy_scripts[0]} \
         -and ! -name ${ses_deploy_scripts[1]} -and ! -name ${ses_deploy_scripts[2]} \
         -exec basename {} \;)
fi
ssh_options="-i ~/.ssh/storage-automation -l root -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
qemu_default_pool="$(sudo virsh pool-dumpxml default | grep path | sed 's/<.path>//; s/<path>//; s/^[ \t]*//')"
libvirt_default_ip="$(sudo virsh net-dumpxml default | awk '/ip address/{print $2}' | cut -d = -f 2 | sed "s/'//g")"

### Creates repo files
cat << EOF > /srv/www/htdocs/current_os.repo
[basesystem]
name=basesystem
type=rpm-md
baseurl=$sle_url/Module-Basesystem/
gpgcheck=0
gpgkey=$sle_url/Module-Basesystem/repodata/repomd.xml.key
enabled=1

[server-applications]
name=server-applications
type=rpm-md
baseurl=$sle_url/Module-Server-Applications/
gpgcheck=0
gpgkey=$sle_url/Module-Server-Applications/repodata/repomd.xml.key
enabled=1

[product-sles]
name=product-sles
type=rpm-md
baseurl=$sle_url/Product-SLES/
gpgcheck=0
gpgkey=$sle_url/Product-SLES/repodata/repomd.xml.key
enabled=1
EOF

cat << EOF > /srv/www/htdocs/current_ses.repo
[SES]
name=SES
type=rpm-md
baseurl=$ses_url
gpgcheck=0
gpgkey=$ses_url/repodata/repomd.xml.key
enabled=1
EOF

### destroy existing cluster
if $destroy ;then
    destroy_existing_cluster
fi

### creates Vagrant box from SLP repo if box not already exists
new_vagrant_box="${sle_slp_dir,,}"
new_vagrant_box="${new_vagrant_box//-/}"
if [ -z "$vagrant_box" ] && [ -z "$(vagrant box list | grep -w $new_vagrant_box)" ];then
    if [ -z "$sle_slp_dir" ] || [ -z "$ses_slp_dir" ];then
        echo "missing --sle_slp_dir or --ses_slp_dir"
        exit 1
    fi
    
    if [ "$(arch)" == "x86_64" ]; then
        if [ -f "/srv/www/htdocs/autoyast_intel.xml" ];then
            sudo mv /srv/www/htdocs/autoyast_intel.xml /srv/www/htdocs/autoyast_intel.xml.$(date +%F-%H%M)
        fi
        sudo cp $(dirname $(realpath $0))/../autoyast/autoyast_intel.xml /srv/www/htdocs/autoyast_intel.xml
        sudo sed -i "s/REPLACE_ME/${sle_url//\//\\/}/g" /srv/www/htdocs/autoyast_intel.xml

        sudo virt-install --name vgrbox --memory 2048 --vcpus 1 --hvm \
        --disk bus=virtio,path=$qemu_default_pool/vgrbox.qcow2,cache=none,format=qcow2,size=10  \
        --network bridge=virbr0,model=virtio --connect qemu:///system  --os-type linux \
        --os-variant sle15sp2 --virt-type kvm --noautoconsole --accelerate \
        --location $sle_url \
        --extra-args="console=tty0 console=ttyS0,115200n8 autoyast=http://$libvirt_default_ip/autoyast_intel.xml"
    elif [ "$(arch)" == "aarch64" ];then
        if [ -f "/srv/www/htdocs/autoyast_aarch64.xml" ];then
            sudo mv /srv/www/htdocs/autoyast_aarch64.xml /srv/www/htdocs/autoyast_aarch64.xml.$(date +%F-%H%M)
        fi
        sudo cp $(dirname $(realpath $0))/../autoyast/autoyast_aarch64.xml /srv/www/htdocs/autoyast_aarch64.xml
        sudo sed -i "s/REPLACE_ME/${sle_url//\//\\/}/g" /srv/www/htdocs/autoyast_aarch64.xml

        sudo virt-install --name vgrbox --memory 2048 --vcpus 1 --hvm \
        --disk bus=virtio,path=$qemu_default_pool/vgrbox.qcow2,cache=none,format=qcow2,size=10  \
        --network bridge=virbr0,model=virtio --connect qemu:///system  --os-type linux \
        --os-variant sle15sp2 --arch aarch64 --noautoconsole --accelerate \
        --location $sle_url \
        --extra-args="console=ttyAMA0,115200n8 autoyast=http://$libvirt_default_ip/autoyast_aarch64.xml"
    fi
    
    echo
    echo "Waiting till vgrbox installation finish"
    while [ "$(sudo virsh domstate vgrbox)" != "shut off" ];do sleep 60;done
    
    echo 
    echo "Starting vgrbox for 2nd stage"
    sudo virsh start vgrbox
    
    sleep 10
    
    echo
    echo "Waiting till vgrbox 2nd stage installation finish"
    while [ "$(sudo virsh domstate vgrbox)" != "shut off" ];do sleep 60;done
    
    vagrant_box="$new_vagrant_box"
    echo "creating vagrant box $vagrant_box"
    
    mkdir -p $VAGRANT_HOME/boxes/$vagrant_box/0/libvirt || exit 1
    
    metadata_json
    vgrvagrantfile
    
    mv $qemu_default_pool/vgrbox.qcow2 $VAGRANT_HOME/boxes/$vagrant_box/0/libvirt/box.img
    
    if [ "$(arch)" == "x86_64" ];then
        sudo virsh undefine vgrbox
    elif [ "$(arch)" == "aarch64" ];then
        sudo virsh undefine vgrbox --nvram
    fi

    
    if [ "$(vagrant box list | grep -w $vagrant_box )" ]; then
        echo "vagrant box $vagrant_box created"; else
        exit 1
    fi
    
    ln -s $VAGRANT_HOME/boxes/$vagrant_box/0/libvirt/box.img $qemu_default_pool/${vagrant_box}_vagrant_box_image_0.img
    
    sudo systemctl restart libvirtd
    
    rm -f /srv/www/htdocs/autoyast_{intel,aarch64}.xml
else
    vagrant_box="$new_vagrant_box"
fi

### destroy existing cluster before deploy (useful for Jenkins)
if $destroy_b4_deploy ;then
    destroy_existing_cluster
fi

### creates nodes and deploys SES 
if ! $existing
then
    if ! $only_salt_cluster
    then
        sed -i 's/deploy_ses: .*/deploy_ses: true/' ${VAGRANT_VAGRANTFILE}.yaml
    else
        sed -i 's/deploy_ses: .*/deploy_ses: false/' ${VAGRANT_VAGRANTFILE}.yaml
    fi

    if [ -z "$vagrant_box" ]
    then
        echo "Missing --vagrant-box-name parameter"
    else
        sed -i "s/ses_cl_box: .*/ses_cl_box: $vagrant_box/" ${VAGRANT_VAGRANTFILE}.yaml
    fi

    vagrant up 

    if [ $? -ne 0 ];then exit 1;fi

    if [ "$(arch)" == "aarch64" ];then
        rsync -aP --delete /etc/libvirt/qemu/ /etc/libvirt/qemu_pflash
    fi
    
    if [ $? -ne 0 ];then exit 1;fi
 
    set_variables

    nodes_list=($(vagrant status | awk '/libvirt/{print $1}'))
    
    vssh_script "${monitors[0]}" "configure_ses.sh" 
    
    create_snapshot "$(echo ${nodes_list[@]})" "deployment"
    
    for node in ${nodes_list[@]}
    do
        sudo virsh start ${project}_${node}
    done
    
    wait_for_health_ok

else
    set_variables
fi
    

### exit if SES only is required 
### or if only Salt cluster is required
if $ses_only &&  $only_salt_cluster || ! $all_scripts && ! $only_script;then
    exit
fi

### runs BV scripts
if $all_scripts
then
    if [ ${#scripts[@]} -eq 0 ]
    then
        exit
    fi
    
    for script in ${scripts[@]}
    do
        vssh_script "${monitors[0]%%.*}" "$script"
        create_snapshot "$(echo ${ses_cluster[@]%%.*})" "$script"
        revert_to_ses
        wait_for_health_ok
    done
elif $only_script
then
    for script in ${one_script[@]}
    do
        vssh_script "${monitors[0]%%.*}" "$script"
        create_snapshot "$(echo ${ses_cluster[@]%%.*})" "$script"
        revert_to_ses
        wait_for_health_ok
    done
fi

failed_scripts="$(sudo virsh snapshot-list --name ${project}_master | grep -v deployment)"
if [ -z "$failed_scripts" ];then
    exit 0
else
    echo "List of failed scripts:"
    echo "$failed_scripts"
    exit 1
fi
