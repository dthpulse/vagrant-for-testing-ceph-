set -ex

monitors=($monitors)
osd_nodes=($osd_nodes)
master=$master

secret="$(awk '/key/{print $3}' /etc/ceph/ceph.client.admin.keyring)"

ceph fs volume create a

ceph fs status 

ceph orch apply nfs 1 --pool cephfs.a.data --namespace nfs-ns

ceph orch ls nfs --refresh

while [ -z "$(ceph orch ps | grep nfs.1)" ]
do
    sleep 10
done

sleep 60

n=1
until [ $n -ge 5 ]
do
   status="$(ceph orch ps --daemon_type nfs --refresh --format json | jq -r .[].status_desc)"
   echo "$status" | grep "running" && break
   n=$((n+1))
   sleep 60
done

if [ ! "$(echo $status | grep "running")" ]; then
    exit 1
fi

rados --pool cephfs.a.data --namespace nfs-ns ls

cat << EOF > export-1
EXPORT {  
    export_id = 1;  
    path = "/";  
    pseudo = "/";  
    access_type = "RW";  
    squash = "no_root_squash";  
    protocols = 3, 4;  
    transports = "TCP", "UDP";  
    FSAL {  
        name = "CEPH";  
        user_id = "admin";  
        filesystem = "a";  
        secret_access_key = "$secret";
    }  
}
EOF

rados --pool cephfs.a.data --namespace nfs-ns put export-1 export-1

cat << EOF > conf-nfs.1
%url "rados://cephfs.a.data/nfs-ns/export-1"
EOF

rados --pool cephfs.a.data --namespace nfs-ns put conf-nfs.1 conf-nfs.1

nfs_server=$(ceph orch restart nfs.1 | awk '{print $NF}')

nfs_server=${nfs_server//\'/}

ssh $nfs_server "systemctl start rpcbind.socket"

mount -t nfs -o nfsvers=4.2 ${nfs_server}:/ /mnt
    
touch /mnt/$HOSTNAME
    
umount /mnt

rm -f conf-nfs.1 export-1
