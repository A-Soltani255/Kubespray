# Kubernetes Firewalld Configuration for Kubespray Nodes

This document describes how to configure `firewalld` for Kubernetes nodes deployed by Kubespray.

The configuration separates traffic into:

* **Management plane**: SSH, Zabbix agent, admin access.
* **Data plane**: Kubernetes API, kubelet API, etcd, Cilium underlay traffic.
* **Trusted Kubernetes overlay**: Cilium interfaces and Pod CIDR traffic.

> **Important:** Apply the **common rules on every node**.
> Apply **master-only rules only on control-plane nodes**.
> Apply **worker-only rules only on worker nodes**.

---

## 1. Start Firewalld

```bash
systemctl enable --now firewalld
```

---

## 2. Remove All Rich Rules From All Zones and Policies

### 2.1 Remove Rich Rules From All Zones

```bash
for z in $(firewall-cmd --get-zones); do
  while IFS= read -r rule; do
    [ -n "$rule" ] && firewall-cmd --permanent --zone="$z" --remove-rich-rule="$rule"
  done < <(firewall-cmd --permanent --zone="$z" --list-rich-rules)
done

firewall-cmd --reload
firewall-cmd --permanent --list-all-zones
```

### 2.2 Remove Rich Rules From All Policies

```bash
for p in $(firewall-cmd --get-policies); do
  while IFS= read -r rule; do
    [ -n "$rule" ] && firewall-cmd --permanent --policy="$p" --remove-rich-rule="$rule"
  done < <(firewall-cmd --permanent --policy="$p" --list-rich-rules)
done

firewall-cmd --reload
firewall-cmd --permanent --list-all-policies
```

---

## 3. Define Variables

```bash
MGMT_IF="$(ip -br -4 a | awk '$3 ~ /^172\.40\.10\./ {print $1; exit}')"
DATA_IF="$(ip -br -4 a | awk '$3 ~ /^192\.168\.10\./ {print $1; exit}')"

POD_CIDR="10.233.64.0/18"
DATA_CIDR="192.168.144.0/24"

ADMIN_NET1="172.40.20.0/24"
ADMIN_NET2="192.168.20.0/24"
KUBESPRAY="172.40.10.10/32"

MASTER1="192.168.144.3/32"
MASTER2="192.168.144.4/32"
MASTER3="192.168.144.5/32"

ZABBIX1="172.40.10.101/32"
ZABBIX2="172.40.10.102/32"

SSH_PORT="22"
```

### Verify Detected Interfaces

```bash
echo "MGMT_IF=$MGMT_IF"
echo "DATA_IF=$DATA_IF"
```

If either variable is empty, stop and fix the IP/interface detection before continuing.

---

## 4. Create Reusable Firewalld Services

### 4.1 SSH on Custom Management Port

```bash
firewall-cmd --permanent --new-service=ssh_22
firewall-cmd --permanent --service=ssh_22 --set-short="SSH 22"
firewall-cmd --permanent --service=ssh_22 --set-description="Management SSH on TCP 22"
firewall-cmd --permanent --service=ssh_22 --add-port=22/tcp
```

### 4.2 Kubernetes API

```bash
firewall-cmd --permanent --new-service=k8s_api
firewall-cmd --permanent --service=k8s_api --set-short="Kubernetes API"
firewall-cmd --permanent --service=k8s_api --set-description="Kubernetes API server on TCP 6443"
firewall-cmd --permanent --service=k8s_api --add-port=6443/tcp
```

### 4.3 Kubelet API

```bash
firewall-cmd --permanent --new-service=kubelet_api
firewall-cmd --permanent --service=kubelet_api --set-short="Kubelet API"
firewall-cmd --permanent --service=kubelet_api --set-description="Kubelet API on TCP 10250"
firewall-cmd --permanent --service=kubelet_api --add-port=10250/tcp
```

### 4.4 Cilium VXLAN Underlay

```bash
firewall-cmd --permanent --new-service=cilium_vxlan
firewall-cmd --permanent --service=cilium_vxlan --set-short="Cilium VXLAN"
firewall-cmd --permanent --service=cilium_vxlan --set-description="Cilium VXLAN tunnel on UDP 8472"
firewall-cmd --permanent --service=cilium_vxlan --add-port=8472/udp
```

### 4.5 Cilium Health

```bash
firewall-cmd --permanent --new-service=cilium_health
firewall-cmd --permanent --service=cilium_health --set-short="Cilium Health"
firewall-cmd --permanent --service=cilium_health --set-description="Cilium cluster health on TCP 4240"
firewall-cmd --permanent --service=cilium_health --add-port=4240/tcp
```

### 4.6 etcd Peer and Client Ports

Use this only if `etcd` is running locally on the master nodes.

```bash
firewall-cmd --permanent --new-service=etcd_peer
firewall-cmd --permanent --service=etcd_peer --set-short="etcd"
firewall-cmd --permanent --service=etcd_peer --set-description="etcd peer and client ports on TCP 2379-2380"
firewall-cmd --permanent --service=etcd_peer --add-port=2379-2380/tcp
```

### 4.7 Zabbix Agent

```bash
firewall-cmd --permanent --new-service=zabbix_agent
firewall-cmd --permanent --service=zabbix_agent --set-short="Zabbix Agent"
firewall-cmd --permanent --service=zabbix_agent --set-description="Zabbix Agent on TCP 10050"
firewall-cmd --permanent --service=zabbix_agent --add-port=10050/tcp
```

---

## 5. Create Reusable Ipsets

### 5.1 Admin Networks

```bash
firewall-cmd --permanent --new-ipset=admin_nets_v4 --type=hash:net
firewall-cmd --permanent --ipset=admin_nets_v4 --add-entry="${ADMIN_NET1}"
firewall-cmd --permanent --ipset=admin_nets_v4 --add-entry="${ADMIN_NET2}"
firewall-cmd --permanent --ipset=admin_nets_v4 --add-entry="${KUBESPRAY}"
```

### 5.2 Cluster Data Subnet

```bash
firewall-cmd --permanent --new-ipset=cluster_data_v4 --type=hash:net
firewall-cmd --permanent --ipset=cluster_data_v4 --add-entry="${DATA_CIDR}"
```

### 5.3 Pod CIDR

```bash
firewall-cmd --permanent --new-ipset=pod_cidr_v4 --type=hash:net
firewall-cmd --permanent --ipset=pod_cidr_v4 --add-entry="${POD_CIDR}"
```

### 5.4 Master Data IPs

```bash
firewall-cmd --permanent --new-ipset=master_data_v4 --type=hash:ip
firewall-cmd --permanent --ipset=master_data_v4 --add-entry="${MASTER1}"
firewall-cmd --permanent --ipset=master_data_v4 --add-entry="${MASTER2}"
firewall-cmd --permanent --ipset=master_data_v4 --add-entry="${MASTER3}"
```

### 5.5 Zabbix Server IPs

```bash
firewall-cmd --permanent --new-ipset=zabbix_servers_v4 --type=hash:ip
firewall-cmd --permanent --ipset=zabbix_servers_v4 --add-entry="${ZABBIX1}"
firewall-cmd --permanent --ipset=zabbix_servers_v4 --add-entry="${ZABBIX2}"
```

---

## 6. Normalize Firewalld Zones

### 6.1 Create Kubernetes Zones

```bash
firewall-cmd --permanent --new-zone=k8s-mgmt
firewall-cmd --permanent --new-zone=k8s-data
```

### 6.2 Set Zone Targets

```bash
firewall-cmd --permanent --zone=k8s-mgmt --set-target=DROP
firewall-cmd --permanent --zone=k8s-data --set-target=DROP
```

### 6.3 Assign Interfaces to Zones

```bash
firewall-cmd --permanent --zone=k8s-mgmt --add-interface="${MGMT_IF}"
firewall-cmd --permanent --zone=k8s-data --add-interface="${DATA_IF}"
```

### 6.4 Trust Cilium Interfaces and Pod CIDR

```bash
firewall-cmd --permanent --zone=trusted --add-interface=cilium_host
firewall-cmd --permanent --zone=trusted --add-interface=cilium_net
firewall-cmd --permanent --zone=trusted --add-interface=cilium_vxlan
firewall-cmd --permanent --zone=trusted --add-source="${POD_CIDR}"
```

### 6.5 Enable Forwarding

```bash
firewall-cmd --permanent --zone=k8s-data --add-forward
firewall-cmd --permanent --zone=trusted --add-forward
```

---

## 7. Create Inter-Zone Policies

### 7.1 Allow Trusted Zone to Reach Kubernetes Data Zone

```bash
firewall-cmd --permanent --new-policy=trst2kd
firewall-cmd --permanent --policy=trst2kd --add-ingress-zone=trusted
firewall-cmd --permanent --policy=trst2kd --add-egress-zone=k8s-data
firewall-cmd --permanent --policy=trst2kd --set-target=ACCEPT
```

### 7.2 Allow Kubernetes Data Zone to Reach Trusted Zone

```bash
firewall-cmd --permanent --new-policy=kd2trst
firewall-cmd --permanent --policy=kd2trst --add-ingress-zone=k8s-data
firewall-cmd --permanent --policy=kd2trst --add-egress-zone=trusted
firewall-cmd --permanent --policy=kd2trst --set-target=ACCEPT
```

### 7.3 Reload Firewalld

```bash
firewall-cmd --reload
```

---

## 8. Common Rules on Every Node

Apply this section on **all Kubernetes nodes**, both masters and workers.

### 8.1 Allow Management SSH From Admin Networks

```bash
firewall-cmd --permanent --zone=k8s-mgmt --add-rich-rule='rule priority=-100 family=ipv4 source ipset=admin_nets_v4 service name="ssh_22" accept'
```

### 8.2 Allow Zabbix Servers to Reach Zabbix Agent

```bash
firewall-cmd --permanent --zone=k8s-mgmt --add-rich-rule='rule priority=-100 family=ipv4 source ipset=zabbix_servers_v4 service name="zabbix_agent" accept'
```

### 8.3 Allow Cilium Underlay and Health Traffic

```bash
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=cluster_data_v4 service name="cilium_vxlan" accept'
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=cluster_data_v4 service name="cilium_health" accept'
```

---

## 9. Master-Only Rules

Apply this section only on **Kubernetes control-plane nodes**.

### 9.1 Allow Kubernetes API Access

Allow Kubernetes API access from:

* Pod CIDR
* Kubernetes data subnet
* Admin networks

```bash
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=pod_cidr_v4 service name="k8s_api" accept'
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=cluster_data_v4 service name="k8s_api" accept'
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=admin_nets_v4 service name="k8s_api" accept'
```

### 9.2 Allow Kubelet Access Among Masters

```bash
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=master_data_v4 service name="kubelet_api" accept'
```

### 9.3 Allow etcd Traffic Among Masters

Use this only if `etcd` is running locally on the master nodes.

```bash
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=master_data_v4 service name="etcd_peer" accept'
```

---

## 10. Worker-Only Rules

Apply this section only on **Kubernetes worker nodes**.

### 10.1 Allow Kubelet Access Only From Masters

```bash
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=-100 family=ipv4 source ipset=master_data_v4 service name="kubelet_api" accept'
```

### 10.2 Trust Required Data Subnets

```bash
firewall-cmd --permanent --zone=trusted --add-source=192.168.117.0/24
firewall-cmd --permanent --zone=trusted --add-source=192.168.147.0/24
firewall-cmd --permanent --zone=trusted --add-source=192.168.144.0/24
```

### 10.3 Trust GitLab Webhook Source

```bash
firewall-cmd --permanent --zone=trusted --add-source=192.168.148.3
```

---

## 11. Optional Logging for Incident Response

These rules log unexpected traffic before the zone target drops it.

### 11.1 Log Unexpected Management Plane Traffic

```bash
firewall-cmd --permanent --zone=k8s-mgmt --add-rich-rule='rule priority=32760 log prefix="K8S-MGMT unexpected " limit value="5/m"'
```

### 11.2 Log Unexpected Data Plane Traffic

```bash
firewall-cmd --permanent --zone=k8s-data --add-rich-rule='rule priority=32760 log prefix="K8S-DATA unexpected " limit value="5/m"'
```

### 11.3 Reload Firewalld

```bash
firewall-cmd --reload
```

---

## 12. Verification Commands

### 12.1 Check Active Zones

```bash
firewall-cmd --get-active-zones
```

### 12.2 Check Kubernetes Management Zone

```bash
firewall-cmd --zone=k8s-mgmt --list-all
```

### 12.3 Check Kubernetes Data Zone

```bash
firewall-cmd --zone=k8s-data --list-all
```

### 12.4 Check Trusted Zone

```bash
firewall-cmd --zone=trusted --list-all
```

### 12.5 Check Firewalld Policies

```bash
firewall-cmd --list-all-policies
```

### 12.6 Check Created Services

```bash
firewall-cmd --permanent --get-services | tr ' ' '\n' | grep -E 'ssh_22|k8s_api|kubelet_api|cilium_vxlan|cilium_health|etcd_peer|zabbix_agent'
```

### 12.7 Check Created Ipsets

```bash
firewall-cmd --permanent --get-ipsets
```

### 12.8 Check Ipset Entries

```bash
firewall-cmd --permanent --ipset=admin_nets_v4 --get-entries
firewall-cmd --permanent --ipset=cluster_data_v4 --get-entries
firewall-cmd --permanent --ipset=pod_cidr_v4 --get-entries
firewall-cmd --permanent --ipset=master_data_v4 --get-entries
firewall-cmd --permanent --ipset=zabbix_servers_v4 --get-entries
```

---

## 13. Connectivity Tests

### 13.1 Test SSH From Admin Network

From an admin host:

```bash
nc -vz <node-management-ip> 1313
```

### 13.2 Test Kubernetes API

From an allowed source:

```bash
nc -vz <master-data-ip> 6443
```

### 13.3 Test Kubelet API

From a master node:

```bash
nc -vz <worker-data-ip> 10250
```

### 13.4 Test Zabbix Agent

From a Zabbix server:

```bash
nc -vz <node-management-ip> 10050
```

### 13.5 Test Cilium VXLAN Port

UDP testing with `nc` is not always reliable, but you can check the firewall rule and Cilium status:

```bash
firewall-cmd --zone=k8s-data --list-rich-rules | grep cilium_vxlan
cilium status
```

---

## 14. Rollback Commands

### 14.1 Remove Custom Zones

```bash
firewall-cmd --permanent --delete-zone=k8s-mgmt
firewall-cmd --permanent --delete-zone=k8s-data
```

### 14.2 Remove Custom Policies

```bash
firewall-cmd --permanent --delete-policy=trst2kd
firewall-cmd --permanent --delete-policy=kd2trst
```

### 14.3 Remove Custom Services

```bash
firewall-cmd --permanent --delete-service=ssh_22
firewall-cmd --permanent --delete-service=k8s_api
firewall-cmd --permanent --delete-service=kubelet_api
firewall-cmd --permanent --delete-service=cilium_vxlan
firewall-cmd --permanent --delete-service=cilium_health
firewall-cmd --permanent --delete-service=etcd_peer
firewall-cmd --permanent --delete-service=zabbix_agent
```

### 14.4 Remove Custom Ipsets

```bash
firewall-cmd --permanent --delete-ipset=admin_nets_v4
firewall-cmd --permanent --delete-ipset=cluster_data_v4
firewall-cmd --permanent --delete-ipset=pod_cidr_v4
firewall-cmd --permanent --delete-ipset=master_data_v4
firewall-cmd --permanent --delete-ipset=zabbix_servers_v4
```

### 14.5 Reload Firewalld

```bash
firewall-cmd --reload
```

---

## 15. Safety Notes

* Do not apply `DROP` targets before confirming SSH access is allowed.
* Keep an active SSH session open while applying firewall changes.
* Confirm `MGMT_IF` and `DATA_IF` are detected correctly before assigning interfaces to zones.
* Use `--permanent` with `firewall-cmd --reload` only after verifying the intended rules.
* Avoid trusting large networks unless they are required.
* Be careful with the `trusted` zone because traffic in this zone is broadly accepted.
* Apply master-only rules only on master nodes.
* Apply worker-only rules only on worker nodes.
* If using Cilium in a mode other than VXLAN, verify whether UDP `8472` is still required.
* If `etcd` is external, do not apply local etcd peer rules on the masters.
