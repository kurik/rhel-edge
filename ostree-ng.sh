#!/bin/bash
set -euox pipefail

# Provision the software under test.
./setup.sh

# Get OS data.
source /etc/os-release

# Set up variables.
ARCH=$(uname -m)
TEST_UUID=$(uuidgen)
IMAGE_KEY="ostree-ng-${TEST_UUID}"
QUAY_REPO_URL="docker://quay.io/rhel-edge/edge-containers"
QUAY_REPO_TAG=$(tr -dc a-z0-9 < /dev/urandom | head -c 4 ; echo '')
BIOS_GUEST_ADDRESS=192.168.100.50
UEFI_GUEST_ADDRESS=192.168.100.51
PROD_REPO=/var/www/html/repo
STAGE_REPO_ADDRESS=192.168.200.1
STAGE_OCP4_SERVER_NAME="edge-stage-server"
STAGE_OCP4_REPO_URL="http://${STAGE_OCP4_SERVER_NAME}-${QUAY_REPO_TAG}-rhel-edge.apps.ocp-c1.prod.psi.redhat.com/repo/"
CONTAINER_IMAGE_TYPE=edge-container
INSTALLER_IMAGE_TYPE=edge-installer
CONTAINER_FILENAME=container.tar
INSTALLER_FILENAME=installer.iso
PROD_REPO_URL=http://192.168.100.1/repo
PROD_REPO_URL_2="${PROD_REPO_URL}/"
STAGE_REPO_URL="http://${STAGE_REPO_ADDRESS}:8080/repo/"
ON_GCP="false"
ANSIBLE_USER="installeruser"
# Container image registry pushing feature
CONTAINER_PUSHING_FEAT="false"
# Embedded container image into OSTree commits feature
EMBEDDED_CONTAINER="false"
# Workaround BZ#2108646
BOOT_ARGS="uefi"
ANSIBLE_OS_NAME="rhel"

# Set up temporary files.
TEMPDIR=$(mktemp -d)
BLUEPRINT_FILE=${TEMPDIR}/blueprint.toml
QUAY_CONFIG=${TEMPDIR}/quay_config.toml
COMPOSE_START=${TEMPDIR}/compose-start-${IMAGE_KEY}.json
COMPOSE_INFO=${TEMPDIR}/compose-info-${IMAGE_KEY}.json

# SSH setup.
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key

# New version mkksiso: Move kickstart to --ks KICKSTART
NEW_MKKSISO="false"

case "${ID}-${VERSION_ID}" in
    "rhel-8.6")
        OSTREE_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        ;;
    "rhel-8.7")
        OSTREE_REF="rhel/8/${ARCH}/edge"
        OS_VARIANT="rhel8-unknown"
        CONTAINER_PUSHING_FEAT="true"
        EMBEDDED_CONTAINER="true"
        ;;
    "rhel-9.0")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9.0"
        ;;
    "rhel-9.1")
        OSTREE_REF="rhel/9/${ARCH}/edge"
        OS_VARIANT="rhel9.0"
        NEW_MKKSISO="true"
        CONTAINER_PUSHING_FEAT="true"
        EMBEDDED_CONTAINER="true"
        ;;
    "centos-8")
        OSTREE_REF="centos/8/${ARCH}/edge"
        OS_VARIANT="centos-stream8"
        sudo dnf install -y dmidecode
        sudo dmidecode -s system-product-name | grep "Google Compute Engine" && ON_GCP="true"
        # for debugging on openstack
        # sudo dmidecode -s system-product-name | grep "OpenStack Compute" && ON_GCP="true"
        CONTAINER_PUSHING_FEAT="true"
        EMBEDDED_CONTAINER="true"
        ;;
    "centos-9")
        OSTREE_REF="centos/9/${ARCH}/edge"
        OS_VARIANT="centos-stream9"
        sudo dnf install -y dmidecode
        sudo dmidecode -s system-product-name | grep "Google Compute Engine" && ON_GCP="true"
        # for debugging on openstack
        # sudo dmidecode -s system-product-name | grep "OpenStack Compute" && ON_GCP="true"
        NEW_MKKSISO="true"
        CONTAINER_PUSHING_FEAT="true"
        EMBEDDED_CONTAINER="true"
        BOOT_ARGS="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
        ;;
    "fedora-36")
        CONTAINER_IMAGE_TYPE=fedora-iot-container
        INSTALLER_IMAGE_TYPE=fedora-iot-installer
        sudo dnf install -y dmidecode
        sudo dmidecode -s system-product-name | grep "Google Compute Engine" && ON_GCP="true"
        OSTREE_REF="fedora/36/${ARCH}/iot"
        OS_VARIANT="fedora36"
        ANSIBLE_OS_NAME="fedora"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

# Re-define STAGE_OCP4_REPO_URL for CRC on GCP
if [[ $ON_GCP == "true" ]]; then
    STAGE_OCP4_REPO_URL="http://${STAGE_OCP4_SERVER_NAME}-${QUAY_REPO_TAG}-default.apps-crc.testing/repo/"
fi

# Colorful output.
function greenprint {
    echo -e "\033[1;32m${1}\033[0m"
}

# modify existing kickstart by prepending and appending commands
function modksiso {
    isomount=$(mktemp -d)
    kspath=$(mktemp -d)

    iso="$1"
    newiso="$2"

    echo "Mounting ${iso} -> ${isomount}"
    sudo mount -v -o ro "${iso}" "${isomount}"

    cleanup() {
        sudo umount -v "${isomount}"
        rmdir -v "${isomount}"
        rm -rv "${kspath}"
    }

    trap cleanup RETURN

    ksfiles=("${isomount}"/*.ks)
    ksfile="${ksfiles[0]}"  # there shouldn't be more than one anyway
    echo "Found kickstart file ${ksfile}"

    ksbase=$(basename "${ksfile}")
    newksfile="${kspath}/${ksbase}"
    oldks=$(cat "${ksfile}")
    echo "Preparing modified kickstart file"
    cat > "${newksfile}" << EOFKS
text
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
${oldks}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for user admin and installeruser
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
echo -e 'installeruser\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
# add remote prod edge repo
ostree remote delete ${ANSIBLE_OS_NAME}
ostree remote add --no-gpg-verify --no-sign-verify ${ANSIBLE_OS_NAME} ${PROD_REPO_URL}
%end
EOFKS

    echo "Writing new ISO"
    if [[ "$NEW_MKKSISO" == "true" ]]; then
        sudo mkksiso -c "console=ttyS0,115200" --ks "${newksfile}" "${iso}" "${newiso}"
    else
        sudo mkksiso -c "console=ttyS0,115200" "${newksfile}" "${iso}" "${newiso}"
    fi

    echo "==== NEW KICKSTART FILE ===="
    cat "${newksfile}"
    echo "============================"
}

# Get the compose log.
get_compose_log () {
    COMPOSE_ID=$1
    LOG_FILE=osbuild-${ID}-${VERSION_ID}-ng-${COMPOSE_ID}.log

    # Download the logs.
    sudo composer-cli compose log "$COMPOSE_ID" | tee "$LOG_FILE" > /dev/null
}

# Get the compose metadata.
get_compose_metadata () {
    COMPOSE_ID=$1
    METADATA_FILE=osbuild-${ID}-${VERSION_ID}-ng-${COMPOSE_ID}.json

    # Download the metadata.
    sudo composer-cli compose metadata "$COMPOSE_ID" > /dev/null

    # Find the tarball and extract it.
    TARBALL=$(basename "$(find . -maxdepth 1 -type f -name "*-metadata.tar")")
    sudo tar -xf "$TARBALL" -C "${TEMPDIR}"
    sudo rm -f "$TARBALL"

    # Move the JSON file into place.
    sudo cat "${TEMPDIR}"/"${COMPOSE_ID}".json | jq -M '.' | tee "$METADATA_FILE" > /dev/null
}

# Build ostree image.
build_image() {
    blueprint_name=$1
    image_type=$2

    # Get worker unit file so we can watch the journal.
    WORKER_UNIT=$(sudo systemctl list-units | grep -o -E "osbuild.*worker.*\.socket")
    sudo journalctl -af -n 1 -u "${WORKER_UNIT}" &
    WORKER_JOURNAL_PID=$!

    # Start the compose.
    greenprint "🚀 Starting compose"
    if [ $# -eq 2 ]; then
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    fi
    if [ $# -eq 3 ]; then
        repo_url=$3
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" --url "$repo_url" "$blueprint_name" "$image_type" | tee "$COMPOSE_START"
    fi
    if [ $# -eq 4 ]; then
        image_repo_url=$3
        registry_config=$4
        sudo composer-cli --json compose start-ostree --ref "$OSTREE_REF" "$blueprint_name" "$image_type" "$image_repo_url" "$registry_config" | tee "$COMPOSE_START"
    fi
    COMPOSE_ID=$(jq -r '.body.build_id' "$COMPOSE_START")

    # Wait for the compose to finish.
    greenprint "⏱ Waiting for compose to finish: ${COMPOSE_ID}"
    while true; do
        sudo composer-cli --json compose info "${COMPOSE_ID}" | tee "$COMPOSE_INFO" > /dev/null

        COMPOSE_STATUS=$(jq -r '.body.queue_status' "$COMPOSE_INFO")

        # Is the compose finished?
        if [[ $COMPOSE_STATUS != RUNNING ]] && [[ $COMPOSE_STATUS != WAITING ]]; then
            break
        fi

        # Wait 30 seconds and try again.
        sleep 5
    done

    # Capture the compose logs from osbuild.
    greenprint "💬 Getting compose log and metadata"
    get_compose_log "$COMPOSE_ID"
    get_compose_metadata "$COMPOSE_ID"

    # Did the compose finish with success?
    if [[ $COMPOSE_STATUS != FINISHED ]]; then
        echo "Something went wrong with the compose. 😢"
        exit 1
    fi

    # Stop watching the worker journal.
    sudo kill ${WORKER_JOURNAL_PID}
}

# Wait for the ssh server up to be.
# Test user admin added by edge-container bp
wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

# Clean up our mess.
clean_up () {
    greenprint "🧼 Cleaning up"

    # Clear vm
    if [[ $(sudo virsh domstate "${IMAGE_KEY}-uefi") == "running" ]]; then
        sudo virsh destroy "${IMAGE_KEY}-uefi"
    fi
    sudo virsh undefine "${IMAGE_KEY}-uefi" --nvram
    sudo virsh vol-delete --pool images "${IMAGE_KEY}-uefi.qcow2"

    # Remove all the containers and images if exist
    sudo podman system reset --force

    # Remove prod repo.
    sudo rm -rf "$PROD_REPO"

    # Remomve tmp dir.
    sudo rm -rf "$TEMPDIR"

    # Remove ISO
    sudo rm -f "/var/lib/libvirt/images/${ISO_FILENAME}"

    # Stop httpd
    sudo systemctl disable httpd --now
}

# Test result checking
check_result () {
    greenprint "Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        greenprint "💚 Success"
    else
        greenprint "❌ Failed"
        clean_up
        exit 1
    fi
}

# Setup CodeReady Containers
setup_crc () {
    # Download CRC first
    wget -4 https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz
    sudo tar xf crc-linux-amd64.tar.xz -C /usr/bin --strip-components 1
    rm -f crc-linux-amd64.tar.xz

    # Configure CRC
    crc config set consent-telemetry no
    crc config set disable-update-check true
    crc config set kubeadmin-password foobar
    crc config set skip-check-daemon-systemd-sockets true
    crc config set skip-check-daemon-systemd-unit true
    crc config set pull-secret-file "$CRC_PULL_SECRET_FILE"

    # Start CRC
    crc setup
    crc start
}

###########################################################
##
## Prepare ostree prod repo and configure stage repo
##
###########################################################
greenprint "Prepare ostree prod repo and configure stage repo"
sudo rm -rf "$PROD_REPO"
sudo mkdir -p "$PROD_REPO"
sudo ostree --repo="$PROD_REPO" init --mode=archive
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-stage "$STAGE_REPO_URL"
sudo ostree --repo="$PROD_REPO" remote add --no-gpg-verify edge-stage-ocp4 "$STAGE_OCP4_REPO_URL"

###########################################################
##
## rhel-edge container image for building installer image
##
###########################################################

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "container"
description = "A base rhel-edge container image"
version = "0.0.1"
modules = []
groups = []
[[packages]]
name = "python3"
version = "*"
[[customizations.user]]
name = "admin"
description = "Administrator account"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/admin/"
groups = ["wheel"]
EOF

# RHEL 8.7 and 9.1 later support embeded container in commit
if [[ "${EMBEDDED_CONTAINER}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[containers]]
source = "quay.io/fedora/fedora:latest"
EOF
fi

greenprint "📄 Which blueprint are we using"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve container

if [[ $CONTAINER_PUSHING_FEAT == "true" ]]; then
    # Write the registry configuration.
    greenprint "📄 Preparing quay.io config to push image"
    tee "$QUAY_CONFIG" > /dev/null << EOF
provider = "container"
[settings]
username = "$QUAY_USERNAME"
password = "$QUAY_PASSWORD"
EOF
    # Omit the "docker://" prefix at QUAY_REPO_URL
    QUAY_REPO_URL_AUX=$(echo ${QUAY_REPO_URL} | grep -oP '(quay.*)')
    # Build container image.
    build_image container "${CONTAINER_IMAGE_TYPE}" "${QUAY_REPO_URL_AUX}:${QUAY_REPO_TAG}" "$QUAY_CONFIG"
else
    build_image container "${CONTAINER_IMAGE_TYPE}"
    # Download the image
    greenprint "📥 Downloading the image"
    sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
    # Clear container running env
    greenprint "🧹 Clearing container running env"
    # Remove any status containers if exist
    sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
    # Remove all images
    sudo podman rmi -f -a
    # Deal with rhel-edge container
    greenprint "Uploading image to quay.io"
    IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
    sudo skopeo copy --dest-creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "oci-archive:${IMAGE_FILENAME}" "${QUAY_REPO_URL}:${QUAY_REPO_TAG}"
    # Clear image file
    sudo rm -f "$IMAGE_FILENAME"

fi

# Prepare rhel-edge container network
greenprint "Prepare container network"
sudo podman network inspect edge >/dev/null 2>&1 || sudo podman network create --driver=bridge --subnet=192.168.200.0/24 --gateway=192.168.200.254 edge

# Run stage repo in OCP4
greenprint "Running stage repo in OCP4"
if [[ $ON_GCP == "true" ]]; then
    setup_crc
    eval "$(crc oc-env)"
    oc login https://api.crc.testing:6443 -u kubeadmin -p foobar
else
    oc login --token="${OCP4_TOKEN}" --server=https://api.ocp-c1.prod.psi.redhat.com:6443 -n rhel-edge --insecure-skip-tls-verify
fi

oc process -f tools/edge-stage-server-template.yaml -p EDGE_STAGE_REPO_TAG="${QUAY_REPO_TAG}" -p EDGE_STAGE_SERVER_NAME="${STAGE_OCP4_SERVER_NAME}" | oc apply -f -

for LOOP_COUNTER in $(seq 0 60); do
    RETURN_CODE=$(curl -o /dev/null -s -w "%{http_code}" "${STAGE_OCP4_REPO_URL}refs/heads/${OSTREE_REF}")
    if [[ $RETURN_CODE == 200 ]]; then
        echo "Stage repo is ready"
        break
    fi
    sleep 10
done

# Sync installer ostree content
greenprint "Sync ostree repo with stage repo"
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage-ocp4 "$OSTREE_REF"

# Clean up OCP4
greenprint "Clean up OCP4"
if [[ $ON_GCP == "true" ]]; then
    crc delete --force
else
    oc delete pod,rc,service,route,dc -l app="${STAGE_OCP4_SERVER_NAME}-${QUAY_REPO_TAG}"
fi

# Clean compose and blueprints.
greenprint "🧹 Clean up compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete container > /dev/null

greenprint "Remove tag from quay.io repo"
skopeo delete --creds "${QUAY_USERNAME}:${QUAY_PASSWORD}" "${QUAY_REPO_URL}:${QUAY_REPO_TAG}"

########################################################
##
## rhel-edge installer image building from container image
##
########################################################

# Write a blueprint for installer image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "installer"
description = "A base rhel-edge installer image"
version = "0.0.1"
modules = []
groups = []
[[customizations.user]]
name = "${ANSIBLE_USER}"
description = "Added by installer blueprint"
password = "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl."
key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCzxo5dEcS+LDK/OFAfHo6740EyoDM8aYaCkBala0FnWfMMTOq7PQe04ahB0eFLS3IlQtK5bpgzxBdFGVqF6uT5z4hhaPjQec0G3+BD5Pxo6V+SxShKZo+ZNGU3HVrF9p2V7QH0YFQj5B8F6AicA3fYh2BVUFECTPuMpy5A52ufWu0r4xOFmbU7SIhRQRAQz2u4yjXqBsrpYptAvyzzoN4gjUhNnwOHSPsvFpWoBFkWmqn0ytgHg3Vv9DlHW+45P02QH1UFedXR2MqLnwRI30qqtaOkVS+9rE/dhnR+XPpHHG+hv2TgMDAuQ3IK7Ab5m/yCbN73cxFifH4LST0vVG3Jx45xn+GTeHHhfkAfBSCtya6191jixbqyovpRunCBKexI5cfRPtWOitM3m7Mq26r7LpobMM+oOLUm4p0KKNIthWcmK9tYwXWSuGGfUQ+Y8gt7E0G06ZGbCPHOrxJ8lYQqXsif04piONPA/c9Hq43O99KPNGShONCS9oPFdOLRT3U= ostree-image-test"
home = "/home/installeruser/"
groups = ["wheel"]
EOF

greenprint "📄 Which blueprint are we using"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve installer

# Build installer image.
# Test --url arg following by URL with tailling slash for bz#1942029
build_image installer "${INSTALLER_IMAGE_TYPE}" "${PROD_REPO_URL_2}"

# Download the image
greenprint "📥 Downloading the image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null
ISO_FILENAME="${COMPOSE_ID}-${INSTALLER_FILENAME}"
modksiso "${ISO_FILENAME}" "/var/lib/libvirt/images/${ISO_FILENAME}"
sudo rm -f "${ISO_FILENAME}"

# Clean compose and blueprints.
greenprint "🧹 Clean up compose"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete installer > /dev/null

########################################################
##
## install rhel-edge image with installer(ISO)
##
########################################################

# Ensure SELinux is happy with our new images.
greenprint "👿 Running restorecon on image directory"
sudo restorecon -Rv /var/lib/libvirt/images/

# Create qcow2 file for virt install.
greenprint "💾 Create qcow2 files for virt install"
LIBVIRT_BIOS_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}-bios.qcow2
LIBVIRT_UEFI_IMAGE_PATH=/var/lib/libvirt/images/${IMAGE_KEY}-uefi.qcow2
sudo qemu-img create -f qcow2 "${LIBVIRT_BIOS_IMAGE_PATH}" 20G
sudo qemu-img create -f qcow2 "${LIBVIRT_UEFI_IMAGE_PATH}" 20G

# Install ostree image via ISO on BIOS vm
greenprint "💿 Install ostree image via installer(ISO) on BIOS vm"
sudo virt-install  --name="${IMAGE_KEY}-bios" \
                   --disk path="${LIBVIRT_BIOS_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:30 \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --cdrom "/var/lib/libvirt/images/${ISO_FILENAME}" \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${IMAGE_KEY}-bios"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for LOOP_COUNTER in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $BIOS_GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

# Get ostree commit value.
greenprint "🕹 Get ostree install commit value"
INSTALL_HASH=$(curl "${PROD_REPO_URL_2}refs/heads/${OSTREE_REF}")

# Run Edge test on BIOS VM
# Add instance IP address into /etc/ansible/hosts
# Run BIOS VM test with installeruser added by edge-installer bp as ansible user
sudo tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${BIOS_GUEST_ADDRESS}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Test IoT/Edge OS
greenprint "📼 Run Edge tests on BIOS VM"
sudo ANSIBLE_STDOUT_CALLBACK=yaml ansible-playbook -v -i "${TEMPDIR}"/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${INSTALL_HASH}" -e ostree_ref="${ANSIBLE_OS_NAME}:${OSTREE_REF}" -e embedded_container="${EMBEDDED_CONTAINER}" check-ostree.yaml || RESULTS=0
check_result

# Clean BIOS VM
if [[ $(sudo virsh domstate "${IMAGE_KEY}-bios") == "running" ]]; then
    sudo virsh destroy "${IMAGE_KEY}-bios"
fi
sudo virsh undefine "${IMAGE_KEY}-bios"
sudo sudo virsh vol-delete --pool images "${IMAGE_KEY}-bios.qcow2"

# Install ostree image via ISO on UEFI vm
greenprint "💿 Install ostree image via installer(ISO) on UEFI vm"
sudo virt-install  --name="${IMAGE_KEY}-uefi" \
                   --disk path="${LIBVIRT_UEFI_IMAGE_PATH}",format=qcow2 \
                   --ram 3072 \
                   --vcpus 2 \
                   --network network=integration,mac=34:49:22:B0:83:31 \
                   --os-type linux \
                   --os-variant "${OS_VARIANT}" \
                   --cdrom "/var/lib/libvirt/images/${ISO_FILENAME}" \
                   --boot ${BOOT_ARGS} \
                   --nographics \
                   --noautoconsole \
                   --wait=-1 \
                   --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "${IMAGE_KEY}-uefi"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for LOOP_COUNTER in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $UEFI_GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check image installation result
check_result

#################################################
#
# upgrade rhel-edge with new upgrade container
#
#################################################

# Write a blueprint for ostree image.
tee "$BLUEPRINT_FILE" > /dev/null << EOF
name = "upgrade"
description = "An upgrade ostree image"
version = "0.0.2"
modules = []
groups = []
[[packages]]
name = "python3"
version = "*"
[[packages]]
name = "wget"
version = "*"
EOF

# ANSIBLE_OS_NAME is a check-ostree.yaml playbook variable defined as "rhel" just for RHEL and CS systems, otherwise is "fedora"
if [[ "${ANSIBLE_OS_NAME}" == "rhel" ]]; then
    tee -a "$BLUEPRINT_FILE" >> /dev/null << EOF
[customizations.kernel]
name = "kernel-rt"
EOF
fi

# RHEL 8.7 and 9.1 later support embeded container in commit
if [[ "${CONTAINER_PUSHING_FEAT}" == "true" ]]; then
    tee -a "$BLUEPRINT_FILE" > /dev/null << EOF
[[containers]]
source = "quay.io/fedora/fedora:latest"
EOF
fi

greenprint "📄 Which blueprint are we using"
cat "$BLUEPRINT_FILE"

# Prepare the blueprint for the compose.
greenprint "📋 Preparing blueprint"
sudo composer-cli blueprints push "$BLUEPRINT_FILE"
sudo composer-cli blueprints depsolve upgrade

# Build installer image.
# Test --url arg following by URL without tailling slash for bz#1942029
build_image upgrade "${CONTAINER_IMAGE_TYPE}" "$PROD_REPO_URL"

# Download the image
greenprint "📥 Downloading the upgrade image"
sudo composer-cli compose image "${COMPOSE_ID}" > /dev/null

# Clear container running env
greenprint "🧹 Clearing container running env"
# Remove any status containers if exist
sudo podman ps -a -q --format "{{.ID}}" | sudo xargs --no-run-if-empty podman rm -f
# Remove all images
sudo podman rmi -f -a

# Deal with rhel-edge container
greenprint "🗜 Extracting and running the image"
IMAGE_FILENAME="${COMPOSE_ID}-${CONTAINER_FILENAME}"
sudo podman pull "oci-archive:${IMAGE_FILENAME}"
sudo podman images
# Clear image file
sudo rm -f "$IMAGE_FILENAME"
# Get image id to run image
EDGE_IMAGE_ID=$(sudo podman images --filter "dangling=true" --format "{{.ID}}")
sudo podman run -d --name rhel-edge --network edge --ip "$STAGE_REPO_ADDRESS" "$EDGE_IMAGE_ID"
# Wait for container to be running
until [ "$(sudo podman inspect -f '{{.State.Running}}' rhel-edge)" == "true" ]; do
    sleep 1;
done;

# Pull upgrade to prod repo
sudo ostree --repo="$PROD_REPO" pull --mirror edge-stage "$OSTREE_REF"
sudo ostree --repo="$PROD_REPO" static-delta generate "$OSTREE_REF"
sudo ostree --repo="$PROD_REPO" summary -u

# Get ostree commit value.
greenprint "🕹 Get ostree upgrade commit value"
UPGRADE_HASH=$(curl "${PROD_REPO_URL_2}refs/heads/${OSTREE_REF}")

# Clean compose and blueprints.
greenprint "Clean up osbuild-composer again"
sudo composer-cli compose delete "${COMPOSE_ID}" > /dev/null
sudo composer-cli blueprints delete upgrade > /dev/null

# Upgrade image/commit.
# Test user admin added by edge-container bp
greenprint "Upgrade ostree image/commit"
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${UEFI_GUEST_ADDRESS}" 'sudo rpm-ostree upgrade'
sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" "admin@${UEFI_GUEST_ADDRESS}" 'nohup sudo systemctl reboot &>/dev/null & exit'

# Sleep 10 seconds here to make sure vm restarted already
sleep 10

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
# shellcheck disable=SC2034  # Unused variables left for readability
for LOOP_COUNTER in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $UEFI_GUEST_ADDRESS)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

# Check ostree upgrade result
check_result

# Add instance IP address into /etc/ansible/hosts
# Test user installeruser added by edge-installer bp
# User installer still exists after upgrade but upgrade bp does not contain installeruer
sudo tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${UEFI_GUEST_ADDRESS}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=${ANSIBLE_USER}
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

# Test IoT/Edge OS
sudo ANSIBLE_STDOUT_CALLBACK=yaml ansible-playbook -v -i "${TEMPDIR}"/inventory -e os_name="${ANSIBLE_OS_NAME}" -e ostree_commit="${UPGRADE_HASH}" -e ostree_ref="${ANSIBLE_OS_NAME}:${OSTREE_REF}" -e embedded_container="${EMBEDDED_CONTAINER}" check-ostree.yaml || RESULTS=0
check_result

# Final success clean up
clean_up

exit 0

