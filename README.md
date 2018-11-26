# OpenWRT LXD Gateway on bare Ubuntu OS
Default LAN IP: 192.168.1.1    
Default Credentials:    
Username: root    
Password: admin    
    
Tested on Ubuntu Bionic 18.04 LTS   
Instructions intended for use on clean Ubuntu OS with one physical nic port (ens3 in this guide)   
NOTICE: No previous configuration of network/ovs/lxd accounted for.
    
#### 00. Add CCIO remote
````sh
lxc remote add ccio https://images.braincraft.io --public --accept-certificate
````

#### 01. Install Packages
````sh
apt update && apt upgrade -y && apt dist-upgrade -y
apt install -y openvswitch-switch ifupdown lxd
````

#### 02. Eliminate netplan due to ovs support (BUG: 1728134)
````sh
sed 's/^/#/g' /etc/netplan/*.yaml
````

#### 03. Create default "interfaces" file
````sh
cat <<EOF >/etc/network/interfaces
# /etc/network/interfaces
auto lo                                                                                   
iface lo inet loopback

# Run interfaces.d config files
source /etc/network/interfaces.d/*.cfg
EOF
````

#### 04. Create wan bridge interfaces file
````sh
cat <<EOF >/etc/network/interfaces.d/wan.cfg
allow-hotplug wan
iface wan inet manual
EOF
````

#### 05. Create ens3 interfaces file
###### (Substitute 'ens3' for your devices physical port)
````sh
cat <<EOF >/etc/network/interfaces.d/ens3.cfg
# Raise ens3 on ovs-br 'wan' with no IP
allow-hotplug ens3
iface ens3 inet manual
EOF
````

#### 06. Create lan bridge interfaces file
````sh
cat <<EOF >/etc/network/interfaces.d/lan.cfg
allow-hotplug lan
iface lan inet manual
EOF
````

#### 07. Create mgmt0 interfaces file
````sh
cat <<EOF >/etc/network/interfaces.d/mgmt0.cfg
# Raise host mgmt0 iface on ovs-br 'lan' with no IP
allow-hotplug mgmt0
iface mgmt0 inet static
  address 192.168.1.5
  gateway 192.168.1.1
  netmask 255.255.255.0
  nameservers 192.168.1.1
  mtu 1500
EOF
````

#### 08. Create WAN Bridge && add WAN port to bridge
````sh
ovs-vsctl add-br wan -- add-port wan ens3
````

#### 09. Generate unique MAC address for mgmt0 iface
````sh
export HWADDRESS=$(echo "$HOSTNAME lan mgmt0" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02\\:\1\\:\2\\:\3\\:\4\\:\5/')
````

#### 10. Create LAN Bridge && add LAN Host MGMT0 Virtual Interface to Bridge
````sh
ovs-vsctl add-br lan -- add-port lan mgmt0 -- set interface mgmt0 type=internal -- set interface mgmt0 mac="$HWADDRESS"
````

#### 11. Initialize LXD
````sh
cat <<EOF | lxd init --preseed
config:
  images.auto_update_interval: "0"
cluster: null
networks: []
storage_pools:
- config:
    size: 15GB
  description: ""
  name: default
  driver: btrfs
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      nictype: macvlan
      parent: lan
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
EOF
````

#### 12. Create OpenWRT LXD Profile
````sh
lxc profile copy default openwrt
lxc profile set openwrt security.privileged true
lxc profile device set openwrt eth0 parent wan
lxc profile device add openwrt eth1 nic nictype=bridged parent=lan
````

#### 13. Launch Gateway
````sh
lxc launch bcio:openwrt gateway -p openwrt && sleep 30 && lxc list
````

#### 15. Reboot host system & inherit!
````sh
reboot
````

## FINISHED!!
Find your WebUI in a lan side browser @ 192.168.1.1    
    
    
---------------------------------------------------------------------------------    
    
    
## ProTip 1:
Enable Luci WebUI on WAN port 80
````sh
lxc exec gateway -- enable-webui-on-wan'
````

    
    
## ProTip 2:
Use as physical network gateway by adding 2nd physical NIC to ovs bridge 'lan'    
(Substitute 'ens6' for your devices physical port)    
    
#### Create ifupdown config for physical lan port
````sh
cat <<EOF >/etc/network/interfaces.d/ens6.cfg
# Raise ens6 on ovs-br 'wan' with no IP
allow-hotplug ens6
iface ens6 inet manual
EOF
````
    
#### Add physical lan port to ovs bridge 'lan'
````sh
ovs-vsctl add-port lan ens6
````
    
    
---------------------------------------------------------------------------------    
# CREDITS:
  - https://github.com/openwrt
  - https://github.com/mikma/lxd-openwrt
  - https://github.com/DavBfr/lxd-openwrt
  - https://github.com/melato/openwrt-lxd 
  - http://www.gnuton.org/blog/2016/02/lxc-on-openwrt/
  - https://forum.archive.openwrt.org/viewtopic.php?id=67358
  - https://discuss.linuxcontainers.org/t/run-openwrt-inside-lxd/1469
  - https://www.reddit.com/r/openwrt/comments/7c9kkr/openwrtlede_in_docker_x86_64/
  - https://discuss.linuxcontainers.org/t/lxd-success-on-openwrt-privileged-containers-but-problems-with-unprivileged/1729
