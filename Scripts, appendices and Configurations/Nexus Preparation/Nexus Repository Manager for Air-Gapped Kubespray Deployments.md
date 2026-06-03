# Nexus Repository Manager for Air-Gapped Kubespray Deployments


**Purpose**

This runbook documents the complete build of a Sonatype Nexus Repository Manager server on Rocky Linux 10.1 for an air-gapped Kubespray/Kubernetes environment.

Use this document as the repository-service appendix for your Kubespray documentation. The Nexus server provides the offline RPM repositories, private package access, and private container registry that Kubespray nodes need before, during, and after cluster deployment.

It includes:

- offline host preparation
- Nexus installation as a systemd service
- local PKI and TLS certificate creation
- Nginx reverse proxy for the Nexus UI and package repository access
- a Docker registry port exposed over HTTPS through Nginx
- private package consumption with no anonymous access
- Docker and containerd client trust and authentication
- firewalld design for a two-interface server
- troubleshooting, validation, backup, rollback, and operational guidance

This document is written as a practical runbook. It is intentionally long, explicit, and operational. The goal is that another engineer can execute the same scenario without searching elsewhere.

---

## 0. How this document fits into the Kubespray documentation

This document should be referenced from the main Kubespray build guide before the node-preparation and cluster-deployment sections.

Recommended placement:

```text
Kubespray Documentation
├── 01-prerequisites.md
├── 02-offline-repositories.md        <-- link to this document here
├── 03-node-preparation.md
├── 04-kubespray-inventory.md
├── 05-cluster-deployment.md
└── Scripts, appendices and Configurations/
    └── Nexus Repository Manager for Air-Gapped Kubespray Deployments.md
```

Recommended link from the main Kubespray Markdown file:

```markdown
[Open Nexus Repository Manager for Air-Gapped Kubespray Deployments](./Scripts,%20appendices%20and%20Configurations/Nexus%20Repository%20Manager%20for%20Air-Gapped%20Kubespray%20Deployments.md)
```

### 0.1 Why Kubespray needs this server

In an air-gapped Kubespray deployment, nodes usually need three offline sources:

1. **RPM/package repository**
   - used to install OS packages, container runtime packages, troubleshooting tools, and dependencies

2. **Container image registry**
   - used by containerd or Docker to pull Kubernetes, CNI, DNS, ingress, monitoring, and application images

3. **Stable internal TLS endpoint**
   - used so all nodes trust the same internal CA and do not depend on public internet certificate chains

This Nexus/Nginx design provides those services behind stable internal HTTPS endpoints.

### 0.2 Deployment order

Use this order:

1. Build the Nexus repository server.
2. Upload RPM repositories and container images.
3. Trust the internal CA on all Kubespray, master, and worker nodes.
4. Configure DNF/YUM on all Linux nodes.
5. Configure containerd registry trust/mirrors.
6. Run Kubespray node preparation.
7. Run Kubespray deployment.
8. Validate image pulls, package access, and cluster health.

### 0.3 Important boundary

This document builds the offline repository platform. It does not replace the Kubespray inventory, Kubespray `offline.yml`, or image-list preparation. Those are still documented in the Kubespray deployment runbook.

---

## 1. Final target design

### 1.1 Scenario summary

The final design implemented in this runbook is:

- **Operating system:** Rocky Linux 10.1
- **Nexus version used in this runbook:** Nexus Repository 3.90.2-01
- **Repository manager data path:** `/opt/sonatype-work/nexus3`
- **Nexus UI/backend:** Nexus listens on local HTTP `127.0.0.1:8081`
- **External UI/packages endpoint:** Nginx terminates TLS on `443/tcp`
- **External Docker endpoint:** Nginx terminates TLS on `5000/tcp`
- **Internal Docker connector:** Nexus Docker hosted repository uses **HTTP** on `15000/tcp`
- **Anonymous access:** disabled for package consumption
- **Package repository design:** private **Raw hosted** repository containing the Rocky tree exactly as uploaded
- **Docker repository design:** private **Docker hosted** repository exposed on `5000/tcp`
- **Host networking:** two interfaces
  - one management interface for SSH only on `22/tcp`
  - one repository interface for `443/tcp` and `5000/tcp`

### 1.2 Why this design was selected

This design was chosen because it is operationally cleaner than trying to force Nexus to serve direct HTTPS on a Docker connector port.

The key decisions were:

1. **Keep Nexus simple internally**
   - Nexus serves local HTTP on `8081`
   - Nexus serves local HTTP for the Docker hosted repo on `15000`
   - Nginx is responsible for TLS at the edge

2. **Do not enable the Nexus Docker connector as HTTPS directly**
   - direct Nexus HTTPS on a Docker connector is possible, but it introduces keystore and connector startup complexity
   - in this scenario, the connector did not bind when configured as direct HTTPS
   - moving TLS termination to Nginx gave a simpler, more supportable design

3. **Keep package repository access private**
   - anonymous access was intentionally not used
   - DNF/YUM clients authenticate with a dedicated read-only service account

4. **Use a Raw hosted repository for the Rocky tree**
   - the existing repository tree already had valid `repodata/`
   - uploading the tree into a Raw repository preserves the exact file layout
   - DNF can consume the uploaded tree directly over HTTPS

5. **Separate management and consumption networks**
   - management interface: only SSH `22/tcp`
   - repository interface: only `443/tcp` and `5000/tcp`
   - no exposure of internal ports such as `8081` or `15000`

---

## 2. Reference variables used throughout this runbook

Adjust these values to match your environment before running commands.

```bash
# identity
NEXUS_VER='3.90.2-01'
NEXUS_FQDN='nexus.soltani.co'
NEXUS_UI_URL="https://${NEXUS_FQDN}"

# server IPs
MGMT_IP='172.40.10.20'
REPO_IP='192.168.10.20'

# interfaces
MGMT_IF="$(ip -br -4 a | awk '$3 ~ /^172\.40\.10\./ {print $1; exit}')"
REPO_IF="$(ip -br -4 a | awk '$3 ~ /^192\.168\.10\./ {print $1; exit}')"

# ports
SSH_PORT='22'
NEXUS_UI_PORT='443'
DOCKER_EXTERNAL_PORT='5000'
NEXUS_HTTP_BACKEND='8081'
NEXUS_DOCKER_BACKEND='15000'

# directories
OFFLINE_DIR='/root/offline'
NEXUS_INSTALL_BASE='/opt/sonatype'
NEXUS_INSTALL_DIR="${NEXUS_INSTALL_BASE}/nexus-${NEXUS_VER}"
NEXUS_LINK="${NEXUS_INSTALL_BASE}/nexus"
NEXUS_DATA='/opt/sonatype-work/nexus3'
NEXUS_BLOB_BASE='/srv/nexus/blobs'
TLS_DIR='/etc/pki/nexus'
ROCKY_SRC='/mnt/rocky-10.1'        # existing Rocky repository tree

# nexus repository names
RAW_REPO='Rocky-10.1'
DOCKER_HOSTED='docker-hosted'

# service accounts
RPM_READER='rpm-reader'
DOCKER_WRITER='docker-writer'
```

### 2.1 Variable guidance

- `NEXUS_FQDN` must match the server certificate.
- `REPO_IP` is the IP that package clients, Docker, and containerd will use.
- `ROCKY_SRC` must point to the local directory that contains your mirrored Rocky tree with valid `repodata/`.
- `DOCKER_EXTERNAL_PORT` is the registry port clients will use.
- `NEXUS_DOCKER_BACKEND` is internal only and must not be exposed externally.

---

## 3. Offline prerequisites

Before starting, place all required installation files on the Nexus host.

### 3.1 Required inputs

You need the following available offline:

- Nexus Repository 3.90.2-01 Unix/Linux tarball
- optional checksum file for the Nexus tarball
- Rocky Linux 10.1 repository content mounted locally under `/mnt` or another local path
- the RPM packages required to install:
  - `nginx`
  - `openssl`
  - `tar`
  - `firewalld`
  - `policycoreutils-python-utils`
- access to the Rocky GPG key on the host

### 3.2 Assumptions

This runbook assumes:

- the server has no internet access
- the server can install packages from the locally mounted Rocky repository
- DNS or `/etc/hosts` resolution exists for `NEXUS_FQDN`
- the local Rocky tree already contains valid `repodata/`
- Docker and containerd clients will trust an internal CA certificate

---

## 4. Use the local Rocky repository on the Nexus host itself

Because this host is air-gapped and already has Rocky repository content mounted locally, use a temporary local DNF repository file pointing to the filesystem.

### 4.1 Find the correct local repository paths

First locate `repomd.xml` files.

```bash
find /mnt -type f -name repomd.xml
```

Use the parent directory of each `repodata/` directory as the `baseurl=file:///...` path.

### 4.2 Example local repo file

```bash
sudo tee /etc/yum.repos.d/local-rocky.repo >/dev/null <<'EOF'
[local-baseos]
name=Rocky 10.1 BaseOS Local
baseurl=file:///mnt/BaseOS/x86_64/os/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10

[local-appstream]
name=Rocky 10.1 AppStream Local
baseurl=file:///mnt/AppStream/x86_64/os/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
EOF
```

### 4.3 Validate local package access

```bash
sudo dnf clean all
sudo rm -rf /var/cache/dnf
sudo dnf makecache
sudo dnf repolist
```

If `dnf makecache` fails here, fix the local file-based repo paths before moving on.

---

## 5. Install operating system packages required for the build

```bash
sudo dnf install -y \
  nginx \
  openssl \
  tar \
  firewalld \
  policycoreutils-python-utils
```

### 5.1 What these packages are for

- `nginx` -> external HTTPS endpoints on `443` and `5000`
- `openssl` -> CA and certificate creation
- `tar` -> unpack Nexus
- `firewalld` -> zone-based network policy
- `policycoreutils-python-utils` -> SELinux tools such as `semanage` and `setsebool`

### 5.2 Verify installation

```bash
rpm -q nginx openssl tar firewalld policycoreutils-python-utils
```

---

## 6. Create the Nexus service account and directory layout

```bash
sudo -i
set -euxo pipefail

getent group nexus || groupadd --system nexus
id nexus || useradd --system --no-create-home --gid nexus --shell /sbin/nologin nexus

mkdir -p \
  "$NEXUS_INSTALL_BASE" \
  "$NEXUS_DATA" \
  "$NEXUS_BLOB_BASE" \
  "$TLS_DIR/private"

chown -R nexus:nexus "$NEXUS_INSTALL_BASE" "$NEXUS_DATA" "$NEXUS_BLOB_BASE"
chmod 750 "$NEXUS_DATA" "$NEXUS_BLOB_BASE"
chmod 700 "$TLS_DIR/private"
```

### 6.1 Why these locations matter

- install directory and data directory are separated
- blob stores are separated from the default data path
- TLS key material is stored under a dedicated private directory

### 6.2 Verify

```bash
ls -ld "$NEXUS_INSTALL_BASE" "$NEXUS_DATA" "$NEXUS_BLOB_BASE" "$TLS_DIR" "$TLS_DIR/private"
id nexus
```

---

## 7. Install Nexus Repository from the offline tarball

Copy the Nexus tarball to the offline staging directory first.

### 7.1 Extract Nexus

```bash
sudo -i
set -euxo pipefail

mkdir -p "$OFFLINE_DIR"
ls -lh "$OFFLINE_DIR"

tar -xzf "$OFFLINE_DIR/nexus-${NEXUS_VER}-unix.tar.gz" -C "$NEXUS_INSTALL_BASE"
ln -sfn "$NEXUS_INSTALL_DIR" "$NEXUS_LINK"

cat > "$NEXUS_LINK/bin/nexus.rc" <<'EOF'
run_as_user="nexus"
EOF

chown -R nexus:nexus "$NEXUS_INSTALL_BASE"
```

### 7.2 Verify the extraction

```bash
ls -ld "$NEXUS_INSTALL_DIR" "$NEXUS_LINK"
cat "$NEXUS_LINK/bin/nexus.rc"
```

---

## 8. Configure Nexus runtime paths and bind the UI to localhost only

The UI/backend listener must remain internal because Nginx will be the only external entry point.

### 8.1 Edit `nexus.vmoptions`

```bash
sudo -i
set -euxo pipefail

cp -a "$NEXUS_LINK/bin/nexus.vmoptions" "$NEXUS_LINK/bin/nexus.vmoptions.bak"

sed -i \
  -e 's#^-Dkaraf.data=.*#-Dkaraf.data=/opt/sonatype-work/nexus3#' \
  -e 's#^-Djava.io.tmpdir=.*#-Djava.io.tmpdir=/opt/sonatype-work/nexus3/tmp#' \
  -e 's#^-XX:LogFile=.*#-XX:LogFile=/opt/sonatype-work/nexus3/log/jvm.log#' \
  -e 's#^-Dkaraf.log=.*#-Dkaraf.log=/opt/sonatype-work/nexus3/log#' \
  "$NEXUS_LINK/bin/nexus.vmoptions"

mkdir -p "$NEXUS_DATA"/{tmp,log,etc}

cat > "$NEXUS_DATA/etc/nexus.properties" <<'EOF'
application-port=8081
application-host=127.0.0.1
nexus-context-path=/
EOF

chown -R nexus:nexus "$NEXUS_DATA"
```

### 8.2 Verify

```bash
grep -E 'karaf.data|java.io.tmpdir|LogFile|karaf.log' "$NEXUS_LINK/bin/nexus.vmoptions"
cat "$NEXUS_DATA/etc/nexus.properties"
```

### 8.3 Important note

Do not expose `8081/tcp` externally.

It must remain reachable only on `127.0.0.1` and only Nginx should talk to it.

---

## 9. Create the Nexus systemd service

```bash
sudo tee /etc/systemd/system/nexus.service >/dev/null <<'EOF'
[Unit]
Description=Sonatype Nexus Repository
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=nexus
Group=nexus
LimitNOFILE=65536
LimitNPROC=65536
ExecStart=/opt/sonatype/nexus/bin/nexus start
ExecStop=/opt/sonatype/nexus/bin/nexus stop
Restart=on-abort
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nexus
```

### 9.1 Verify the installed unit

```bash
systemctl cat nexus
```

---

## 10. Create a long-lived internal CA and server certificate

Use an internal CA and sign the Nexus/Nginx server certificate with it.

Do not try to create a truly non-expiring certificate. Use a long validity such as 10 years and manage it intentionally.

### 10.1 Create the CA and server certificate

```bash
sudo -i
set -euxo pipefail

cat > "$TLS_DIR/openssl-san.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
CN = ${NEXUS_FQDN}
O  = Airgap
OU = Nexus

[ req_ext ]
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[ alt_names ]
DNS.1 = ${NEXUS_FQDN}
IP.1  = ${REPO_IP}
IP.2  = 127.0.0.1
EOF

openssl genrsa -out "$TLS_DIR/private/nexus-ca.key" 4096

openssl req -x509 -new -nodes \
  -key "$TLS_DIR/private/nexus-ca.key" \
  -sha256 \
  -days 3650 \
  -subj "/CN=Airgap Nexus Root CA/O=Airgap/OU=PKI" \
  -out "$TLS_DIR/nexus-ca.crt"

openssl genrsa -out "$TLS_DIR/private/${NEXUS_FQDN}.key" 4096

openssl req -new \
  -key "$TLS_DIR/private/${NEXUS_FQDN}.key" \
  -out "$TLS_DIR/${NEXUS_FQDN}.csr" \
  -config "$TLS_DIR/openssl-san.cnf"

openssl x509 -req \
  -in "$TLS_DIR/${NEXUS_FQDN}.csr" \
  -CA "$TLS_DIR/nexus-ca.crt" \
  -CAkey "$TLS_DIR/private/nexus-ca.key" \
  -CAcreateserial \
  -out "$TLS_DIR/${NEXUS_FQDN}.crt" \
  -days 3650 \
  -sha256 \
  -extensions req_ext \
  -extfile "$TLS_DIR/openssl-san.cnf"

chmod 600 "$TLS_DIR/private/"*.key
```

### 10.2 Verify certificate contents

```bash
openssl x509 -in "$TLS_DIR/${NEXUS_FQDN}.crt" -noout -text | egrep 'Subject:|DNS:|IP Address:|Not After'
```

### 10.3 Why the SAN entries matter

Clients will connect using the FQDN and possibly the repository IP during troubleshooting.

If the certificate SAN list does not match the way clients connect, TLS verification will fail even if the CA is trusted.

---

## 11. Trust the internal CA on the Nexus host itself

```bash
sudo cp -f "$TLS_DIR/nexus-ca.crt" /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### 11.1 Verify

```bash
trust list | grep -i 'Airgap Nexus Root CA' || true
```

---

## 12. Start Nexus for the first time

```bash
sudo systemctl enable --now nexus
sleep 20
sudo systemctl status nexus --no-pager -l || true
sudo ss -lntp | egrep '127.0.0.1:8081|:8081'
```

### 12.1 Validate local HTTP reachability

```bash
curl -I http://127.0.0.1:8081/
journalctl -u nexus -b --no-pager | tail -n 100
```

If Nexus takes longer than expected on first boot, watch the logs live:

```bash
journalctl -u nexus -f
```

---

## 13. Configure Nginx for the Nexus UI on 443 and Docker on 5000

### 13.1 Why Nginx is used for both 443 and 5000

In the final design:

- `443/tcp` is Nginx TLS -> Nexus UI/backend on `127.0.0.1:8081`
- `5000/tcp` is Nginx TLS -> Nexus Docker hosted repo on `127.0.0.1:15000`

This avoids the complexity of direct Nexus HTTPS connectors for Docker.

### 13.2 UI vhost on 443

```bash
sudo tee /etc/nginx/conf.d/nexus-ui.conf >/dev/null <<EOF
server {
    listen ${REPO_IP}:80;
    server_name ${NEXUS_FQDN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${REPO_IP}:443 ssl http2;
    server_name ${NEXUS_FQDN};

    ssl_certificate     ${TLS_DIR}/${NEXUS_FQDN}.crt;
    ssl_certificate_key ${TLS_DIR}/private/${NEXUS_FQDN}.key;

    client_max_body_size 0;
    proxy_send_timeout 600;
    proxy_read_timeout 600;
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:8081/;
        proxy_pass_header Server;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
```

### 13.3 Docker TLS vhost on 5000

First, the Docker repository in Nexus must be configured as **HTTP on 15000**, not HTTPS.

Then add the Nginx listener:

```bash
sudo tee /etc/nginx/conf.d/nexus-docker-5000.conf >/dev/null <<EOF
server {
    listen ${REPO_IP}:5000 ssl;
    server_name ${NEXUS_FQDN};

    ssl_certificate     ${TLS_DIR}/${NEXUS_FQDN}.crt;
    ssl_certificate_key ${TLS_DIR}/private/${NEXUS_FQDN}.key;

    client_max_body_size 0;
    proxy_read_timeout 900;
    proxy_send_timeout 900;
    proxy_connect_timeout 60;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;
    chunked_transfer_encoding on;

    location / {
        proxy_pass http://127.0.0.1:${NEXUS_DOCKER_BACKEND};
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
```

### 13.4 SELinux and Nginx backend connections

```bash
sudo setsebool -P httpd_can_network_connect 1
```

### 13.5 Validate and start Nginx

```bash
sudo nginx -t
sudo systemctl enable --now nginx
sudo ss -lntp | egrep ':(443|5000)\s'
```

### 13.6 Validate TLS endpoints locally

```bash
curl -kI https://${NEXUS_FQDN}/
curl -kI https://${NEXUS_FQDN}:5000/v2/ || true
```

For the Docker endpoint, a `401 Unauthorized` response is expected when the endpoint is alive but authentication is required.

---

## 14. Configure the Docker hosted repository in Nexus

### 14.1 Important final design rule

Do **not** check **HTTPS** on the Nexus Docker connector in this design.

Use:

- **HTTP** connector enabled
- port = `15000`
- external TLS handled by Nginx on `5000`

### 14.2 Why this matters

When the Docker connector was configured directly as HTTPS on `5000`, the port did not bind. The simpler and more reliable final design is:

- Nexus Docker connector: local HTTP only
- Nginx: external TLS endpoint on `5000`

### 14.3 Validate the internal Docker connector

After saving the Docker hosted repo with HTTP `15000`, restart Nexus if needed and verify:

```bash
sudo systemctl restart nexus
sleep 20
sudo ss -lntp | egrep ':(8081|15000)\s' || true
curl -sv http://127.0.0.1:15000/v2/ || true
```

A `401 Unauthorized` response from `/v2/` is correct for a private Docker repository.

---

## 15. First login to Nexus and required UI configuration

### 15.1 Get the initial admin password

```bash
sudo cat "$NEXUS_DATA/admin.password"
```

Login to the UI at:

```text
https://nexus.soltani.co/
```

Change the admin password immediately.

### 15.2 Create blob stores

Create dedicated blob stores for separation and cleaner operations. Example:

- `blob-raw-rocky` -> `/srv/nexus/blobs/raw-rocky`
- `blob-docker` -> `/srv/nexus/blobs/docker`

### 15.3 Create repositories

#### A. Raw hosted repository for Rocky content

Create a **Raw hosted** repository named:

```text
Rocky-10.1
```

Use blob store:

```text
blob-raw-rocky
```

This repository will store the mirrored Rocky tree exactly as uploaded.

#### B. Docker hosted repository

Create a **Docker hosted** repository named:

```text
docker-hosted
```

Settings:

- HTTP connector enabled on `15000`
- HTTPS connector disabled
- blob store `blob-docker`

### 15.4 Enable required realm

Under **Security -> Realms**, move **Docker Bearer Token Realm** to active realms.

This is required for Docker client authentication.

### 15.5 Base URL

Set the Base URL capability to:

```text
https://nexus.soltani.co
```

---

## 16. Upload the Rocky repository tree into the Raw hosted repository

This runbook assumes your local Rocky mirror already exists under `$ROCKY_SRC` and contains valid `repodata/`.

### 16.1 Create a dedicated upload user

Create a Nexus user for repository upload operations. Do **not** use `admin` for day-to-day upload work.

Example:

```text
raw-uploader
```

Grant only the minimum required permissions for uploading to the Raw hosted repository.

### 16.2 Upload script

```bash
sudo -i
set -euxo pipefail

export ROCKY_SRC='/mnt/rocky-10.1'
export NEXUS_HOST='nexus.soltani.co'
export NEXUS_RAW_REPO='Rocky-10.1'
export NEXUS_USER='raw-uploader'
export NEXUS_PASS='CHANGE_ME'

cd "$ROCKY_SRC"

find . -type f -print0 | while IFS= read -r -d '' f; do
  rel="${f#./}"
  echo "Uploading: $rel"
  curl --fail --show-error --silent \
    --user "${NEXUS_USER}:${NEXUS_PASS}" \
    --upload-file "$f" \
    "https://${NEXUS_HOST}/repository/${NEXUS_RAW_REPO}/${rel}"
done
```

### 16.3 Upload validation

Pick a known file and verify it is reachable:

```bash
curl -I "https://${NEXUS_FQDN}/repository/${RAW_REPO}/BaseOS/x86_64/os/repodata/repomd.xml"
```

If the repository is private, the anonymous request should return `401` and the authenticated request should return `200`.

Example:

```bash
curl -I -u 'rpm-reader:CHANGE_ME' \
  "https://${NEXUS_FQDN}/repository/${RAW_REPO}/BaseOS/x86_64/os/repodata/repomd.xml"
```

---

## 17. Disable anonymous access for package consumption

The final design intentionally uses **no anonymous access** for the package repository.

### 17.1 Why this was done

- access is controlled and auditable
- private infrastructure packages are not exposed to unauthenticated clients
- service accounts can be scoped to minimal read-only permissions

### 17.2 Create a dedicated read-only package consumer account

Create:

```text
rpm-reader
```

Grant only the permissions required to browse and read the Raw hosted repository that holds the Rocky tree.

### 17.3 Validate with curl before testing DNF

```bash
curl -I -u 'rpm-reader:CHANGE_ME' \
  "https://${NEXUS_FQDN}/repository/${RAW_REPO}/Docker-Ce-Stable/repodata/repomd.xml"
```

Expected result:

```text
HTTP/1.1 200 OK
```

If you see `401`, fix Nexus permissions before touching DNF.

---

## 18. Configure DNF/YUM clients to consume the private package repository

### 18.1 Why `401 Unauthorized` happened previously

A `401` while downloading `repomd.xml` does **not** indicate a TLS problem.

It means:

- HTTPS/TLS succeeded
- the client reached Nexus successfully
- authentication or authorization failed

### 18.2 Example private DNF repo file

```bash
sudo tee /etc/yum.repos.d/rocky-private-nexus.repo >/dev/null <<'EOF'
[rocky-baseos]
name=Rocky 10.1 BaseOS from Nexus
baseurl=https://nexus.soltani.co/repository/Rocky-10.1/BaseOS/x86_64/os/
enabled=1
gpgcheck=1
repo_gpgcheck=0
sslverify=1
sslcacert=/etc/pki/ca-trust/source/anchors/nexus-ca.crt
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
username=rpm-reader
password=CHANGE_ME

[rocky-appstream]
name=Rocky 10.1 AppStream from Nexus
baseurl=https://nexus.soltani.co/repository/Rocky-10.1/AppStream/x86_64/os/
enabled=1
gpgcheck=1
repo_gpgcheck=0
sslverify=1
sslcacert=/etc/pki/ca-trust/source/anchors/nexus-ca.crt
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-10
username=rpm-reader
password=CHANGE_ME
EOF

sudo chmod 600 /etc/yum.repos.d/rocky-private-nexus.repo
```

### 18.3 Trust the internal CA on each Rocky client

```bash
sudo cp -f /path/to/nexus-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### 18.4 Validate DNF repository access

```bash
sudo dnf clean all
sudo rm -rf /var/cache/dnf
sudo dnf makecache
sudo dnf repolist
```

### 18.5 Security note

The `.repo` file stores credentials in plaintext. Protect it with strict file permissions and use a dedicated read-only account.

---

## 19. Configure Docker clients for the private registry on 5000

### 19.1 Design summary

Docker clients connect to:

```text
nexus.soltani.co:5000
```

That endpoint is:

- TLS-terminated by Nginx
- proxied to Nexus Docker HTTP connector on `15000`

### 19.2 Trust the internal CA on Docker clients

```bash
sudo mkdir -p /etc/docker/certs.d/nexus.soltani.co:5000
sudo cp -f /path/to/nexus-ca.crt /etc/docker/certs.d/nexus.soltani.co:5000/ca.crt

sudo cp -f /path/to/nexus-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust

sudo systemctl restart docker
```

### 19.3 Login, tag, push, and pull

```bash
docker login nexus.soltani.co:5000

docker tag nginx:stable nexus.soltani.co:5000/library/nginx:stable
docker push nexus.soltani.co:5000/library/nginx:stable

docker pull nexus.soltani.co:5000/library/nginx:stable
```

### 19.4 Validation sequence

```bash
curl -kI https://nexus.soltani.co:5000/v2/ || true
docker login nexus.soltani.co:5000
docker push nexus.soltani.co:5000/library/nginx:stable
docker pull nexus.soltani.co:5000/library/nginx:stable
```

A `401` on `/v2/` before login is expected for a private registry.

---

## 20. Configure containerd clients for the private registry on 5000

### 20.1 Create CA and `hosts.toml` layout

For a registry endpoint with a port, containerd can search host namespaces using either `host_port_` or `host:port` on Unix. This runbook uses the portable `host_port_` directory form.

```bash
sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo mkdir -p /etc/containerd/certs.d/nexus.soltani.co_5000_

sudo cp -f /path/to/nexus-ca.crt /etc/containerd/certs.d/nexus.soltani.co_5000_/ca.crt

sudo tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<'EOF'
server = "https://docker.io"

[host."https://nexus.soltani.co:5000"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/nexus.soltani.co_5000_/ca.crt"
EOF
```

### 20.2 Direct registry trust for images referenced as `nexus.soltani.co:5000/...`

If your Kubespray inventory or image list references images directly as `nexus.soltani.co:5000/...`, also create a direct host namespace for that registry:

```bash
sudo tee /etc/containerd/certs.d/nexus.soltani.co_5000_/hosts.toml >/dev/null <<'EOF'
server = "https://nexus.soltani.co:5000"

[host."https://nexus.soltani.co:5000"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/nexus.soltani.co_5000_/ca.crt"
EOF
```

Use this direct form when the image name already contains the Nexus registry endpoint.

Use the `docker.io/hosts.toml` mirror form only when containerd must rewrite pulls for `docker.io/...` to the Nexus mirror endpoint.

### 20.3 Ensure `config_path` is set in `config.toml`

#### Containerd 1.x style

```toml
version = 2

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

#### Containerd 2.x style

```toml
version = 3

[plugins."io.containerd.cri.v1.images".registry]
  config_path = "/etc/containerd/certs.d"
```

### 20.4 Optional node-wide credentials in `config.toml`

If you want node-level credentials instead of using `ctr --user` every time:

#### Containerd 1.x style

```toml
[plugins."io.containerd.grpc.v1.cri".registry.configs."docker.io".auth]
  username = "docker-writer"
  password = "CHANGE_ME"
```

#### Containerd 2.x style

```toml
[plugins."io.containerd.cri.v1.images".registry.configs."docker.io".auth]
  username = "docker-writer"
  password = "CHANGE_ME"
```

### 20.5 Restart containerd

```bash
sudo systemctl restart containerd
sudo systemctl status containerd --no-pager -l
```

### 20.6 Validate with `ctr`

```bash
sudo ctr images pull --hosts-dir /etc/containerd/certs.d \
  --user 'docker-writer:CHANGE_ME' \
  docker.io/library/nginx:stable
```

If the image already exists locally in containerd and you want to push it:

```bash
sudo ctr images tag docker.io/library/nginx:stable \
  docker.io/library/nginx:stable

sudo ctr images push --hosts-dir /etc/containerd/certs.d \
  --user 'docker-writer:CHANGE_ME' \
  docker.io/library/nginx:stable
```

---

## 21. Firewalld design for a two-interface Nexus host

### 21.1 Required network model

This server has two interfaces with separate security roles:

- **management interface**
  - purpose: host administration only
  - allow only SSH on `22/tcp`

- **repository interface**
  - purpose: package and image consumption
  - allow `443/tcp` for Nexus UI and package repository access
  - allow `5000/tcp` for Docker registry access

### 21.2 Explicitly forbidden external ports

Do not expose these ports externally:

- `8081/tcp` -> Nexus UI/backend internal HTTP
- `15000/tcp` -> internal Docker HTTP connector
- `80/tcp` -> optional redirect only; not required in a hardened build
- `80/tcp` -> optional HTTP-to-HTTPS redirect only; not required in a hardened build

### 21.3 Create custom firewalld services

Grouping ports into custom services keeps the policy readable.

```bash
sudo firewall-cmd --permanent --new-service=nexus-mgmt
sudo firewall-cmd --permanent --service=nexus-mgmt --set-short='Nexus Management'
sudo firewall-cmd --permanent --service=nexus-mgmt --set-description='SSH management access for Nexus host'
sudo firewall-cmd --permanent --service=nexus-mgmt --add-port=22/tcp

sudo firewall-cmd --permanent --new-service=nexus-repo
sudo firewall-cmd --permanent --service=nexus-repo --set-short='Nexus Repository'
sudo firewall-cmd --permanent --service=nexus-repo --set-description='Nexus HTTPS UI/package access and Docker registry access'
sudo firewall-cmd --permanent --service=nexus-repo --add-port=443/tcp
sudo firewall-cmd --permanent --service=nexus-repo --add-port=5000/tcp
```

### 21.4 Create zones and bind interfaces

```bash
sudo systemctl enable --now firewalld

sudo firewall-cmd --permanent --new-zone=nexus-mgmt
sudo firewall-cmd --permanent --new-zone=nexus-repo

sudo firewall-cmd --permanent --zone=nexus-mgmt --add-interface=${MGMT_IF}
sudo firewall-cmd --permanent --zone=nexus-repo --add-interface=${REPO_IF}

sudo firewall-cmd --permanent --zone=nexus-mgmt --set-target=DROP
sudo firewall-cmd --permanent --zone=nexus-repo --set-target=DROP

sudo firewall-cmd --permanent --zone=nexus-mgmt --add-service=nexus-mgmt
sudo firewall-cmd --permanent --zone=nexus-repo --add-service=nexus-repo

sudo firewall-cmd --reload
```

### 21.5 Set a safe default zone

To ensure unexpected interfaces do not silently land in `public`, move the default zone away from `public`.

```bash
sudo firewall-cmd --set-default-zone=drop
```

### 21.6 Verify firewalld state

```bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --zone=nexus-mgmt --list-all
sudo firewall-cmd --zone=nexus-repo --list-all
```

### 21.7 Deactivate the `public` zone in practice

You do not need to delete the built-in `public` zone. Instead:

- remove all interfaces from `public`
- remove any source networks from `public`
- make sure `public` is not the default zone

Checks:

```bash
sudo firewall-cmd --zone=public --list-all
sudo firewall-cmd --get-default-zone
nmcli -f connection.id,connection.interface-name,connection.zone connection show
```

If NetworkManager still binds a connection to `public`, change it:

```bash
sudo nmcli connection modify '<connection-name>' connection.zone nexus-mgmt
sudo nmcli connection up '<connection-name>'
```

### 21.8 Optional ipset design

If only a specific set of clients should reach the repository interface, use an ipset plus a rich rule.

Example:

```bash
sudo firewall-cmd --permanent --new-ipset=repo_clients --type=hash:ip
sudo firewall-cmd --permanent --ipset=repo_clients --add-entry=192.168.10.1
sudo firewall-cmd --permanent --ipset=repo_clients --add-entry=192.168.10.2

sudo firewall-cmd --permanent --zone=nexus-repo \
  --add-rich-rule='rule source ipset=repo_clients service name=nexus-repo accept'

sudo firewall-cmd --reload
```

Note that ipsets are for source identity grouping. For port grouping, use a firewalld **service**, not an ipset.

---

## 22. Bind services to the correct interface IPs, not all IPs

Firewall rules are necessary, but binding daemons to the correct IP addresses is a stronger design.

### 22.1 Nginx binding

In this runbook, Nginx listeners are explicitly bound to `${REPO_IP}`.

That means the package and Docker endpoints do not listen on the management interface at all.

### 22.2 SSH binding

To keep SSH on the management interface only, update `/etc/ssh/sshd_config`:

```conf
Port 22
ListenAddress 172.40.10.20
```

Validate and restart:

```bash
sudo sshd -t
sudo systemctl restart sshd
sudo ss -lntp | grep ':22 '
```

This prevents SSH from listening on the repository interface.

---

## 23. Nexus privilege model used in this runbook

### 23.1 Repository admin vs repository view

Nexus has two commonly confused privilege families:

- **repository-admin** -> actions on repository configuration
- **repository-view** -> actions on content inside the repository

### 23.2 Meaning in practice

#### `repository-admin`

Use this for engineers who manage repository definitions and settings.

Examples of what it covers:

- viewing repository settings
- editing repository settings
- creating repositories
- deleting repository definitions
- changing connectors, deployment policy, blob store assignment, cleanup policy, and similar settings

#### `repository-view`

Use this for accounts that consume or manipulate artifacts inside repositories.

Examples of what it covers:

- browse repository content in the UI
- read and download content
- upload content
- replace content
- delete content inside the repo

### 23.3 Service account role recommendations

Use separate accounts for separate duties.

Recommended pattern:

- `rpm-reader`
  - browse + read only on the Raw hosted repository containing Rocky content
- `raw-uploader`
  - add/edit only where required for repository uploads
- `docker-writer`
  - read/add/edit on the Docker hosted repository
- `repo-admin`
  - repository-admin privileges only for platform engineers

Do not use `admin` for normal package consumption, image pulls, or image pushes.

---

## 24. Kubespray integration checklist

Use this section from the main Kubespray documentation after the Nexus server is built.

### 24.1 On the Kubespray control machine

The machine that runs Ansible/Kubespray must be able to reach:

```text
https://nexus.soltani.co/
https://nexus.soltani.co:5000/v2/
```

Validate:

```bash
curl -I https://nexus.soltani.co/
curl -I -u 'rpm-reader:CHANGE_ME'   https://nexus.soltani.co/repository/Rocky-10.1/BaseOS/x86_64/os/repodata/repomd.xml
curl -I https://nexus.soltani.co:5000/v2/ || true
```

Expected:

- UI/package endpoint returns a valid HTTP response
- authenticated RPM repository check returns `200`
- Docker registry `/v2/` returns `401 Unauthorized` before login

The `401` on `/v2/` is normal for a private registry.

### 24.2 On every Kubernetes node

Every master and worker node must have:

- the internal CA installed
- DNF/YUM repo files configured if packages are installed from Nexus
- containerd trust configured for the Nexus registry
- DNS or `/etc/hosts` resolution for `nexus.soltani.co`

Minimum validation:

```bash
getent hosts nexus.soltani.co
curl -I https://nexus.soltani.co/
sudo dnf makecache
sudo ctr images pull --hosts-dir /etc/containerd/certs.d   --user 'docker-writer:CHANGE_ME'   nexus.soltani.co:5000/library/nginx:stable
```

### 24.3 Recommended Kubespray documentation note

Add this note to the main Kubespray prerequisite section:

```markdown
Before running Kubespray, the offline Nexus repository server must be available.
All Kubespray, master, and worker nodes must trust the internal Nexus CA and must be able to reach the Nexus package endpoint on `443/tcp` and the Nexus container registry endpoint on `5000/tcp`.
```

### 24.4 Common Kubespray failure symptoms when Nexus is not ready

| Symptom | Likely cause | First check |
|---|---|---|
| `dnf makecache` fails | RPM repository path, credentials, or CA trust issue | `curl -I -u rpm-reader:... repomd.xml` |
| containerd image pull fails with x509 error | CA not installed under containerd registry namespace | check `/etc/containerd/certs.d/.../ca.crt` |
| containerd image pull fails with unauthorized | wrong registry credentials or missing image | `ctr images pull --user ...` |
| Ansible package tasks fail | node cannot reach Nexus `443/tcp` | firewall and DNS |
| Kubernetes pods stay in `ImagePullBackOff` | image missing, wrong tag, auth failure, or registry trust issue | `kubectl describe pod` and containerd logs |

---

## 25. Validation checklist after the build

### 25.1 On the Nexus host

```bash
sudo ss -lntp | egrep ':(22|443|5000|8081|15000)\s'
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --get-default-zone
sudo nginx -t
sudo systemctl status nexus nginx firewalld --no-pager -l
```

Expected result:

- `22` listening on the management IP only
- `443` listening on the repository IP only
- `5000` listening on the repository IP only
- `8081` listening on `127.0.0.1` only
- `15000` listening locally for Nexus Docker connector

### 25.2 On a package client

```bash
curl -I -u 'rpm-reader:CHANGE_ME' \
  https://nexus.soltani.co/repository/Rocky-10.1/BaseOS/x86_64/os/repodata/repomd.xml

sudo dnf clean all
sudo rm -rf /var/cache/dnf
sudo dnf makecache
```

Expected result:

- authenticated `curl` returns `200`
- `dnf makecache` succeeds

### 25.3 On a Docker client

```bash
docker login nexus.soltani.co:5000
docker tag nginx:stable nexus.soltani.co:5000/library/nginx:stable
docker push nexus.soltani.co:5000/library/nginx:stable
docker pull nexus.soltani.co:5000/library/nginx:stable
```

### 25.4 On a containerd client

```bash
sudo ctr images pull --hosts-dir /etc/containerd/certs.d \
  --user 'docker-writer:CHANGE_ME' \
  nexus.soltani.co:5000/library/nginx:stable
```

---

## 26. Troubleshooting section

### 26.1 `dnf makecache` returns `401 Unauthorized`

Meaning:

- TLS is working
- the client reached the server
- auth or authorization failed

Checks:

```bash
curl -vkI https://nexus.soltani.co/repository/Rocky-10.1/BaseOS/x86_64/os/repodata/repomd.xml
curl -I -u 'rpm-reader:CHANGE_ME' \
  https://nexus.soltani.co/repository/Rocky-10.1/BaseOS/x86_64/os/repodata/repomd.xml
```

Fixes:

- ensure anonymous access is disabled intentionally, not accidentally blocking the user
- verify the `rpm-reader` credentials
- verify the account has the necessary browse/read permissions on the repository
- verify the `baseurl=` path is correct

### 26.2 Docker registry port not visible in `ss` or `netstat`

If `5000` is missing but `8081` is present, this usually means the Docker endpoint path is wrong or Nginx is not listening.

Checks:

```bash
sudo ss -lntp | egrep ':(443|5000|8081|15000)\s'
curl -sv http://127.0.0.1:15000/v2/ || true
curl -kI https://nexus.soltani.co:5000/v2/ || true
```

Expected:

- internal connector on `15000` returns `401`
- external Nginx endpoint on `5000` returns `401`

If `15000` is missing, the Docker repository is not configured correctly inside Nexus.

### 26.3 Direct Nexus HTTPS on Docker connector does not bind

Do not continue fighting the direct HTTPS connector in this scenario.

Use the final supported pattern in this runbook:

- Docker connector = HTTP `15000`
- Nginx TLS = external `5000`

### 26.4 Docker login fails with certificate errors

Symptoms:

- `x509: certificate signed by unknown authority`
- certificate verify failure

Checks:

- verify `/etc/docker/certs.d/nexus.soltani.co:5000/ca.crt`
- verify system trust store contains the CA
- verify the server certificate SAN includes the hostname the client actually uses

### 26.5 Containerd pull fails with certificate errors

Checks:

- verify `/etc/containerd/certs.d/nexus.soltani.co_5000_/ca.crt`
- verify `hosts.toml` points to the correct server URL
- verify `config_path = "/etc/containerd/certs.d"`
- verify the certificate SAN includes the hostname

### 26.6 Nginx proxying fails with SELinux

If Nginx returns `502 Bad Gateway` while backend ports are reachable locally, check SELinux first.

```bash
getsebool httpd_can_network_connect
sudo setsebool -P httpd_can_network_connect 1
```

### 26.7 Firewalld troubleshooting

If ports are open in Nginx or Nexus but clients still cannot reach them:

```bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --zone=nexus-mgmt --list-all
sudo firewall-cmd --zone=nexus-repo --list-all
sudo ss -lntp | egrep ':(22|443|5000|8081|15000)\s'
```

Remember:

- firewall does not matter if the service is not listening
- fix listeners first, then firewall

---

## 27. Backup and recovery guidance

### 27.1 What must be backed up

Protect both:

- Nexus metadata/data directory -> `/opt/sonatype-work/nexus3`
- blob stores -> `/srv/nexus/blobs`

### 27.2 Simple offline backup procedure

```bash
sudo systemctl stop nexus

tar -cpf /root/nexus-backup-$(date +%F).tar \
  /opt/sonatype-work/nexus3 \
  /srv/nexus/blobs

sudo systemctl start nexus
```

For large environments, use filesystem snapshots instead of a tar archive.

### 27.3 Recovery concept

To restore the instance, restore both the data directory and the blob stores from the same consistent backup point.

Do not restore one without the other.

---

## 28. Upgrade guidance

### 28.1 Safe upgrade pattern

- review release notes first
- back up the data directory and blob stores
- keep the install directory and data directory separated
- unpack the new tarball alongside the old install
- point the symbolic link at the new version
- restart Nexus
- validate listeners and repository functions

### 28.2 Why install/data separation helps

Because the active runtime points through `/opt/sonatype/nexus`, the install tree can be replaced more cleanly while leaving persistent data untouched.

---

## 29. Rollback procedures

### 29.1 Stop Nexus and Nginx

```bash
sudo systemctl stop nginx nexus
```

### 29.2 Remove Nginx repository endpoint configuration

```bash
sudo rm -f /etc/nginx/conf.d/nexus-ui.conf
sudo rm -f /etc/nginx/conf.d/nexus-docker-5000.conf
sudo nginx -t
sudo systemctl reload nginx
```

### 29.3 Remove Nexus service

```bash
sudo systemctl disable --now nexus
sudo rm -f /etc/systemd/system/nexus.service
sudo systemctl daemon-reload
```

### 29.4 Remove installed Nexus files

```bash
sudo rm -rf "/opt/sonatype/nexus-${NEXUS_VER}"
sudo rm -f /opt/sonatype/nexus
```

### 29.5 Remove Nexus data and blobs

**Destructive**

```bash
sudo rm -rf /opt/sonatype-work/nexus3
sudo rm -rf /srv/nexus/blobs
```

### 29.6 Remove TLS material

```bash
sudo rm -rf /etc/pki/nexus
sudo rm -f /etc/pki/ca-trust/source/anchors/nexus-ca.crt
sudo update-ca-trust
```

### 29.7 Emergency firewall rollback

If you lock yourself out through firewalld during testing and have console access:

```bash
sudo systemctl stop firewalld
```

Use this only for recovery, not as a normal operating mode.

---

## 30. Operational notes and lessons learned

### 30.1 Keep package and image duties separate

Use separate service accounts and separate privileges.

### 30.2 Keep UI/backend internal

Never expose `8081` publicly when Nginx is present.

### 30.3 Keep Docker connector internal when using Nginx TLS

Never expose `15000` externally.

### 30.4 Treat `401` correctly

On package endpoints:

- `401` usually means auth is missing or wrong

On Docker `/v2/` endpoint:

- `401` before login is usually normal and proves the endpoint is alive

### 30.5 Prefer fail-closed networking

Use explicit interface-zone binding and a non-public default zone.

### 30.6 Protect plaintext credentials

DNF repo files and node-level containerd auth entries may contain plaintext credentials. Keep permissions tight and use least-privilege accounts.

---

## 31. Final quick-start checklist

### Build the server

1. mount local Rocky repositories
2. install `nginx`, `openssl`, `tar`, `firewalld`, `policycoreutils-python-utils`
3. create the `nexus` user and directory structure
4. unpack Nexus tarball
5. configure Nexus runtime paths and systemd unit
6. create internal CA and server certificate
7. trust the CA on the Nexus host
8. start Nexus on `127.0.0.1:8081`
9. configure Nginx on `${REPO_IP}:443`
10. configure Nexus Docker hosted repo with **HTTP** connector on `15000`
11. configure Nginx on `${REPO_IP}:5000` to proxy to `15000`
12. enable SELinux boolean for Nginx backend connectivity
13. create Raw hosted repository `Rocky-10.1`
14. upload Rocky mirror tree into Raw hosted repository
15. create Docker hosted repository `docker-hosted`
16. enable Docker Bearer Token Realm
17. create read-only and writer service accounts
18. configure firewalld zones for mgmt and repo interfaces
19. bind SSH only to the management IP
20. validate UI, package repository, Docker, and containerd access

### Consume from clients

1. trust internal CA
2. for DNF, create private `.repo` file with `username=` and `password=`
3. for Docker, install `ca.crt` under `/etc/docker/certs.d/<host:port>/`
4. for containerd, create `/etc/containerd/certs.d/<host_port_>/hosts.toml`
5. log in and validate package, Docker, and containerd operations

---

## 32. Vendor-validation notes used while building this runbook

This runbook was assembled around the final working design and validated against current vendor documentation available at the time of writing for these topics:

- current Nexus Repository download line and install guidance
- Docker routing methods and port connectors in Nexus
- Docker Bearer Token Realm requirement
- containerd `hosts.toml` and host namespace behavior for registries with ports

This document intentionally focuses on the final working implementation rather than reproducing every dead-end in detail.

---

## 33. Main-document link snippet

Use this snippet in the main Kubespray Markdown file:

```markdown
## Offline repository server

Kubespray nodes must use the internal Nexus repository server for RPM packages and container images in the air-gapped environment.

The full Nexus build and validation runbook is documented here:

[Open Nexus Repository Manager for Air-Gapped Kubespray Deployments](./Scripts,%20appendices%20and%20Configurations/Nexus%20Repository%20Manager%20for%20Air-Gapped%20Kubespray%20Deployments.md)
```

