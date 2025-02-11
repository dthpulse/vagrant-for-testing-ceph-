set -ex

# split nodes
function split_nodes(){
    number_of_nodes=$1
    first_part=$(($number_of_nodes / 2))
    second_part=$(($number_of_nodes - $first_part))
}

# wait for cluster health OK
function cluster_health(){
    until [ "$(ceph health)" == HEALTH_OK ]
    do
        sleep 30
    done
}

function iptables_drop() {
    ssh -tt ${1} << EOF
iptables -I OUTPUT -d localhost -j ACCEPT
iptables -I OUTPUT -d $(hostname -f) -j ACCEPT
iptables -I INPUT -s localhost -j ACCEPT
iptables -I INPUT -s $(hostname -f) -j ACCEPT
iptables -P INPUT DROP
iptables -P OUTPUT DROP
exit
EOF
}
# calculating PG and PGP number
num_of_osd=$(ceph osd ls | wc -l)

k=4
m=2

num_of_existing_pools=$(ceph osd pool ls | wc -l)
num_of_pools=1

function power2() { echo "x=l($1)/l(2); scale=0; 2^((x+0.5)/1)" | bc -l; }
size=$(ceph-conf -c /dev/null -D | grep "osd_pool_default_size" | cut -d = -f 2 | sed 's/\ //g')
osd_num=$(ceph osd ls | wc -l)
recommended_pg_per_osd=100
pg_num=$(power2 $(echo "(($osd_num*$recommended_pg_per_osd) / $size) / ($num_of_existing_pools + $num_of_pools)" | bc))
pgp_num=$pg_num
pg_size_total=$(($pg_num*($k+$m)))
until [ $pg_size_total -lt $((200*$num_of_osd)) ]
do
    pg_num=$(($pg_num/2))
    pgp_num=$pg_num
    pg_size_total=$(($pg_num*($k+$m)))
done

function iptables_accept() {
    ssh ${1} -tt << EOF
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F 
exit
EOF
}

function wait_until_down() {
    until ceph -s | grep ".* ${1}.* down"
    do
        sleep 30
    done
    ceph -s 
    ceph osd tree
}

function check_container_exists () {
    local old_container=$1
    local chck_container=$(podman ps | awk 'FNR==2{print $1}')
    if [ "$old_container" != "$chck_container" ]
    then
        container="$chck_container"        
        podman cp /etc/ceph/ceph.client.admin.keyring ${container}:/etc/ceph/ceph.client.admin.keyring
        podman cp /tmp/${crushmap_file}.txt ${container}:/tmp/${crushmap_file}.txt
        podman cp /tmp/${crushmap_file}.bin ${container}:/tmp/${crushmap_file}.bin
    fi
}

domain="${master#*.}"
container=$(podman ps | awk 'FNR==2{print $1}')
crushmap_file="crushmap"
echo "Getting crushmap"
podman cp /etc/ceph/ceph.client.admin.keyring ${container}:/etc/ceph/ceph.client.admin.keyring
podman exec $container ceph osd getcrushmap -o /tmp/${crushmap_file}.bin
podman exec $container crushtool -d /tmp/${crushmap_file}.bin -o /tmp/${crushmap_file}.txt
podman cp ${container}:/tmp/${crushmap_file}.txt /tmp/${crushmap_file}.txt
podman cp ${container}:/tmp/${crushmap_file}.bin /tmp/${crushmap_file}.bin

echo "Getting data from crushmap"
hosts=($(grep ^host /tmp/${crushmap_file}.txt | awk '{print $2}' | sort -u))
root_name=$(grep ^root /tmp/${crushmap_file}.txt | awk '{print $2}')

# exit 1 if storage nodes are less then 4
if [ ${#hosts[@]} -lt 4 ]
then
    echo "Too few nodes with storage role. Minimum is 4."
    exit 1
fi

### rack failure
for i in rack{1..4}
do
    ceph osd crush add-bucket $i rack
    ceph osd crush move $i root=$root_name
done

### region 1
split_nodes ${#hosts[@]}

# nodes for region1
for region1 in $(seq 0 $(($first_part - 1)))
do
    region1_hosts+=(${hosts[$region1]})
done

# split region1 nodes to racks
split_nodes ${#region1_hosts[@]}

# nodes for rack1 in region1
for rack1 in $(seq 0 $(($first_part - 1)))
do
    rack1_hosts+=(${region1_hosts[$rack1]})
done

# nodes for rack2 in region1
for rack2 in $(seq 1 $second_part)
do
    rack2_hosts+=(${region1_hosts[-$rack2]})
done

# move nodes in crush map to rack1 (region1)
for osd_node in ${rack1_hosts[@]}
do
    ceph osd crush move $osd_node rack=rack1
done
 
# move nodes in crush map to rack2 (region1)
for osd_node in ${rack2_hosts[@]}
do
    ceph osd crush move $osd_node rack=rack2
done
 


# region2
split_nodes ${#hosts[@]}

# nodes for region2
for region2 in $(seq 1 $second_part)
do
    region2_hosts+=(${hosts[-$region2]})
done

# split region2 nodes to racks
split_nodes ${#region2_hosts[@]}

# nodes for rack3 in region2
for rack3 in $(seq 0 $(($first_part - 1)))
do
    rack3_hosts+=(${region2_hosts[$rack3]})
done

# nodes for rack4 in region2
for rack4 in $(seq 1 $second_part)
do
    rack4_hosts+=(${region2_hosts[-$rack4]})
done

for osd_node in ${rack3_hosts[@]}
do
    ceph osd crush move $osd_node rack=rack3
done
 
for osd_node in ${rack4_hosts[@]}
do
    ceph osd crush move $osd_node rack=rack4
done
 
# creates pool
echo "Creating pool crushmap"
ceph osd pool create crushmap $pg_num $pgp_num
while [ $(ceph -s | grep creating -c) -gt 0 ]; do echo -n .;sleep 1; done

# get the master hostname
master=$master

# bring down rack
echo "Bringing rack down"
for node2fail in ${rack4_hosts[@]}
do
    iptables_drop ${node2fail}.${domain}
done

wait_until_down "rack"

# bring rack up
echo "Bringing rack up"
for node2fail in ${rack4_hosts[@]}
do
    iptables_accept ${node2fail}.${domain}
done

cluster_health

### DC failure
echo "Simulating DC failure"
ceph osd crush add-bucket dc1 datacenter
ceph osd crush add-bucket dc2 datacenter
ceph osd crush move dc1 root=$root_name
ceph osd crush move dc2 root=$root_name
ceph osd crush move rack1 datacenter=dc1
ceph osd crush move rack2 datacenter=dc1
ceph osd crush move rack3 datacenter=dc2
ceph osd crush move rack4 datacenter=dc2

dc1_nodes=(${rack1_hosts[@]} ${rack2_hosts[@]})
dc2_nodes=(${rack3_hosts[@]} ${rack4_hosts[@]})

# bringing down DC
echo "Bringing DC down"
for node2fail in ${dc1_nodes[@]}
do
    iptables_drop ${node2fail}.${domain}
done

wait_until_down "datacenter"

# bring DC up
echo "Bringing DC up"
for node2fail in ${dc1_nodes[@]}
do
    iptables_accept ${node2fail}.${domain}
done

cluster_health

### region failure
echo "Simulating region failure"
ceph osd crush add-bucket dc3 datacenter
ceph osd crush add-bucket dc4 datacenter
ceph osd crush add-bucket region1 region
ceph osd crush add-bucket region2 region
ceph osd crush move region1 root=$root_name
ceph osd crush move region2 root=$root_name
ceph osd crush move dc1 region=region1
ceph osd crush move dc2 region=region1
ceph osd crush move dc3 region=region2
ceph osd crush move dc4 region=region2
ceph osd crush move rack2 datacenter=dc2
ceph osd crush move rack3 datacenter=dc3
ceph osd crush move rack4 datacenter=dc4

region1_nodes=(${rack1_hosts[@]} ${rack2_hosts[@]})
region2_nodes=(${rack3_hosts[@]} ${rack4_hosts[@]})

# bringing down region
echo "Bringing region down"
for node2fail in ${region1_nodes[@]}
do
    iptables_drop ${node2fail}.${domain}
done

wait_until_down "region"

# bring region up
echo "Bringing region up"
for node2fail in ${region1_nodes[@]}
do
    iptables_accept ${node2fail}.${domain}
done

cluster_health

# remove pool
ceph osd pool rm crushmap crushmap --yes-i-really-really-mean-it

# set back default crushmap
check_container_exists $container
podman exec $container ceph osd setcrushmap -i /tmp/${crushmap_file}.bin

ceph osd crush tree

cluster_health

rm -f /tmp/${crushmap_file}.{txt,bin}
