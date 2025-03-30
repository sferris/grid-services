# Manage external services with Oracle RAC

**Warning**: My environment is not high volume, but lots of clients. This has definitely not been stress tested, and 
doing this with Gitea is likely ill advised. (I have really good backups - just in case)

I wanted a semi-highly available Gitea installation. My design considerations are:

> Real Application Clusters to manage fail-over

I know RAC clusters reasonably well and I manage many of them. There might be better options, but this is a free option. (It only incurs a cost if enabling RAC in a database itself) We'll use an application specific VIP (Virtual IP) that will float between cluster nodes. RAC will manage them both.

> Clustered filesystems

Both ACFS and GFS2 feel very heavy. And ACFS requires pairing Kernel version with RAC version. This means RAC must be upgraded with the OS, or you risk ACFS not starting. I've used OCFS2 in the past, and it's very simple to set up. It's also included with the OS and automatically patched. The down side is that you're basically building 2 clusters. I've not had any issues with this. (One didn't step on the other)

I also want protection against a non-clustered filesystem from being dual mounted and corrupting itself. Clustered filesystems mitigate these problems with a distrubuted lock manager. We should only be accessing the filesystem from a single server at any point in time, but it shouldn't be catastrophic if something does happen. However, we still need to make sure gitea is only started on at most one system. (The combination of RAC and systemd should prevent this w/o re-inventing the wheel)

> Use systemd user services to start and stop

This avoids a lot of complicated code to ensure things are started and running correctly. No lock files, no `ps -ef` logic (w/ false positives/negatives), etc. We'll set `restart=no` to prevent systemd from restarting it, and also leave it disabled so that it doesn't start automatically. Having RAC manage the start/stop has the added bonus of managing a vip, and knowing when there are network issues.

This also a provides a good backup plan if RAC goes down. Just enable restart and enable/start the service manually. You lose fail-over, but should be up and running in seconds. Oh, and did I mentioned there's no special logic that make assumptions of the environment that things are running in. (the systemd scripts don't know RAC exists, and aside from RAC calling systemctl, it doesn't know about systemd)

> Gitea should run under the git user

I don't want to have gitea running as root. I do want gitea to manage ssh vs. the system OS and also use port 22. The OS will be limited to the main interface, and we'll have to set up the gitea executable with cap_net_bind_service privileges.

## Install the clustered filesystem

On Red Hat compatible systems (I used Oracle Enterprise Linux), we'll need to install the ocfs2 tool:
```
sudo dnf install -y ocfs2-tools
```

Create the cluster configuration:
```
sudo o2cb add-cluster ocfs01d
```

Add the servers that will participate in the cluster. Yes, this is redundant because RAC is a cluster, but trust me, this is simpler than ACFS and GFS2.

```
sudo o2cb add-node ocfs01d srvoel10a --ip 10.0.20.17
sudo o2cb add-node ocfs01d srvoel10b --ip 10.0.20.18
```

You should end up with something like this:
```
sudo cat /etc/ocfs2/cluster.conf
cluster:
	heartbeat_mode = local
	node_count = 2
	name = ocfs01d

node:
	number = 0
	cluster = ocfs01d
	ip_port = 7777
	ip_address = 10.0.20.17
	name = srvoel10a

node:
	number = 1
	cluster = ocfs01d
	ip_port = 7777
	ip_address = 10.0.20.18
	name = srvoel10b
```

Complete the configuration:
```
sudo /sbin/o2cb.init configure
```

Enable and start the OCFS2 services:
```
sudo systemctl enable o2cb
sudo systemctl start o2cb

sudo systemctl enable ocfs2
sudo systemctl start ocfs2
```

Create a filesystem on your shared LUN:
```
sudo mkfs.ocfs2 -L “ocfs2” /dev/oracle/ocfs2/6000000000000000000000000000f001-gitrepo 
```

And make it mount persistently upon reboot:
```
sudo cat /etc/fstab
/dev/oracle/ocfs2/6000000000000000000000000000f001-gitrepo  /ocfs/gitea ocfs2 _netdev 0 0
```

The ''_netdev'' option is required to make sure it mounts after the network is started. (Mandatory for iSCSI LUNs as in me test, but I believe this resolves the timing issue on Fiber Channel LUNs too. (I still need to test)


## Create a git user

Since we'll be installing gitea manaully, we need to set up the git account manually. There's nothing hugely special about this, with the exception of use the ''cap_net_bind_service'' capability, and to manage systemd user services.

### The following requires a user with sudo privs

Create the user and group:
```
sudo groupadd  --system git
sudo useradd --home-dir /home/git --gid git --create-home --system --shell /bin/bash --comment 'Gitea repository admin' git
```

Enable systemd to run user services:
```
sudo loginctl enable-linger git
```

This is also a good time to update *sshd* to only bind to the correct interace(s). Update */etc/ssh/sshd_config* and alter the ListenAddress to suit: 
```
#ListenAddress 0.0.0.0
ListenAddress 192.168.21.151
```

*0.0.0.0* will bind to all interfaces. We want it to avoid the VIP we're managing with RAC for Gitea. Unfortunately I couldn't find a method for including all, and excluding a few. Fortunately RAC only needs the main interface, so it isn't a problem. (I might add back the private interface, but only for preference)

Since Gitea will be using it's own VIP for the network access, we get to stick with port 22 also. This can be done using the following:
```
sudo setcap 'cap_net_bind_service=+ep' /home/git/bin/gitea-1.20.3-linux-amd64
```

### As the git user

Create the necessary directories for the repository and systemd
```
rootdir=/ocfs/gitea

mkdir -p "${rootdir}"/{custom,data,log,etc}
chown -R git:git "${rootdir}"/
chmod -R 750 "${rootdir}"
chmod 770 "${rootdir}"/etc
```


## Setup systemd (as git user)

Create the user services directory:
```
mkdir -p ~/.config/systemd/user
```

Create the *~/.config/systemd/user/gitea.service* file with this as the contents: (Also found in this repo: *<repo>/etc/gitea.service)*
```
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target

[Service]
# Uncomment the next line if you have repos with lots of files and get a HTTP 500 error because of that
# LimitNOFILE=524288:524288

# RAC will manage start/stop/relocation
Restart=no
Type=exec

WorkingDirectory=/ocfs/gitea/
ExecStart=/home/git/bin/gitea web --config /ocfs/gitea/etc/app.ini
Environment=USER=git HOME=/home/git GITEA_WORK_DIR=/ocfs/gitea

#[Install]
#WantedBy=default.target
```

Of note here are the `Restart` and `WantedBy` settings. We will not actually let systemd start and/or restart this process. RAC will do that on the appropriate server in the cluster. Should RAC fail completely however, you **can** use systemd to manually start it. Use these 2 settings to accomplish that. There's nothing here that depends on RAC.

Also worth noting that the Gitea example service uses `Type=notify`. This wasn't working for me, even w/o RAC. I haven't looked into it further, but *exec* seems to work just fine for me.
    
## Setup RAC

First we'll need to set up a VIP. (An Ethernet interface+IP that floats between cluster nodes)
One of the existing VIP -might- be suitable for this, but I wanted to keep them separate.

You'll need to determine a suitable IP for the VIP. In the example below I'm using the same
physical interface as RAC's *public* subnet. You can also create a new network which uses a different
physical interface, or a VLAN tagged interface. That is beyond the scope of these instructions however.

The following assumes the variable GH is already set:
```
export GH=/u01/product/grid/linux-x64-19.8.0.0.200714-grid/bin
```


Create the VIP with the IP determined above. The `-network=1` argument specifies the standard *public*
subnet built into RAC. Alter to suit:
```
sudo $GH/bin/appvipcfg create -vipname=rac01d-git.vip -network=1 -ip=192.168.21.158 -user=git -group=git
```

If needed, you can remove it with:
```
sudo $GH/bin/appvipcfg delete -vipname=rac01d-git.vip
```

Next is to create the service. For this, we'll need a file with the resource attributes: (these is
an example in this repo: **repo**/etc/gitea.resource)
```
ACL=owner:git:rwx,pgrp:git:r-x,other::r--
ACTION_SCRIPT=/home/git/bin/gitea.grid
ACTION_TIMEOUT=180
AUTO_START=always
SCRIPT_TIMEOUT=180
CHECK_INTERVAL=300
STOP_DEPENDENCIES=hard(intermediate:rac01d-git.vip)
START_DEPENDENCIES=hard(rac01d-git.vip) attraction(intermediate:rac01d-git.vip)
```

> ACL
    
This attribute essentially give the *git* user the ability to manage this resource, and anyone
in the *git* group the ability to view the status and start/stop the resource.

> ACTION_SCRIPT
    
Set this to the full path of the script that RAC/Grid will use to manage the Gitea service.
It must take 4 actions on the command line: *start*, *stop*, *check*, and *clean*

systemd makes this really simple:

**start** becomes: `systemctl --user start gitea.service`
**stop** becomes: `systemctl --user stop gitea.service`
**check** becomes: `systemctl --user is-active --quiet gitea.service`
**clean** becomes: `systemctl --user stop gitea.service -f`

> AUTO_START
    
This is what will make the service persistent when the system/cluster reboot.

> ACTION_TIMEOUT & SCRIPT_TIMEOUT
    
These define the elapsed time to give up executing any actions. I'm not entirely sure
the nuances between these, but I set them to the same value and it seems to work.

> CHECK_INTERVAL
    
This is how often to check the resource (Eg: execute the *ACTION_SCRIPT* *check* action) to determine
whether the resource is still available. I originally thought about using the Gitea TCP API's to
accomplish this, but I decided against hardcoding token/credentials + I didn't want any confusion whether
the resource was running on the local server, or another server in the cluster. That could get messy.
I assume the API's can be used via unix socket which would help, but still, I'd have to embed a token
which is not ideal. *systemd* has never let me down and is simple.

> STOP_DEPENDENCIES
    
These define the resource dependencies to also stop when stopping the gitea resource. hard() dependencies
are the only option for stopping. *intermediate* means that the resource can remain online as long as the
resource is either in an online or intermediate state. Otherwise it would be shutdown.

*global* and *shutdown* are additional modifiers that can also be used, but global will allow a resource
to be online, not matter where it's running in the cluster. Obviously gitea and the VIP should only be
on the same server.. and shutdown can be used to adjust how things are shutdown when the entire stack is
stopped.

> START_DEPENDENCIES
    
Similar syntax to *STOP_DEPENDENCIES* except for starting dependencies. hard() tells RAC to bring
up the dependecy if it's not already, and attraction() tells RAC that the resource needs to run on
the same node as this service. So, if the VIP is on node2, but you start the gitea service on node 1,
RAC will restart the VIP and relocate it to the same node.

Three are many other options, but documenting them all is beyond the scope of these instructions.
If you have requirements such as services avoiding services on the same node, etc, please consult
the RAC/Grid documentation.

To add this resource:
```
sudo $GH/bin/crsctl add resource rac01d-git.svc -type cluster_resource -file /home/git/bin/gitea.resource
```

To delete this resource:
```
sudo $GH/bin/crsctl delete resource rac01d-git.svc
```
    

