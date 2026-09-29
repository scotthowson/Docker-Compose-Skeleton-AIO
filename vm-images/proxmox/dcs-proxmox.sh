#!/bin/bash
# =============================================================================
# dcs-proxmox.sh — put a DCS VM image on this Proxmox host: a hub VM ready to open in the browser, or a node template
# for the hub to clone. Run it as root on the Proxmox host (the shell of the node).
#
#   ./dcs-proxmox.sh hub  debian-13   [options]   creates and starts a hub VM (tags dcs;hub)
#   ./dcs-proxmox.sh node ubuntu-26.04 --template  a template the hub clones for its stacks (tags dcs;template)
#
# ROLE    hub | node          DISTRO   debian-13 | ubuntu-26.04 | fedora-44
# --vmid ID            default: the next free id
# --name NAME          default: dcs-hub / dcs-node-DISTRO
# --storage STORAGE    where the disk goes (default: local-lvm when it exists)
# --bridge BRIDGE      default: vmbr0
# --cores N --memory MB --disk GB     defaults: hub 2 / 4096 / 32, node 2 / 2048 / 16
# --ip CIDR --gateway IP --dns IP     a static address (default: DHCP)
# --user NAME          the login of the VM (default: dcs)
# --ssh-key FILE       public key(s) for it (default: /root/.ssh/*.pub of this host)
# --password           ask for a password too (the VM works with the key alone)
# --firmware bios|uefi default: bios (SeaBIOS)
# --template           make a template instead of a VM
# --no-start           do not start the VM
# --file PATH          use this image file (default: download from the release)
# --base-url URL       where the release files are (default: the latest release)
# --dry-run            show what would be done, change nothing
# =============================================================================
set -euo pipefail

RELEASE_URL="${DCS_RELEASE_URL:-https://github.com/scotthowson/dcs-orchestrator/releases/latest/download}"
say()  { printf '\033[1;36m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s%s\n' "$([[ ${DRY:-0} == 1 ]] && echo '(dry run, nothing done) ')" "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 1 && ( "$1" == -h || "$1" == --help ) ]] && usage 0
[[ $# -ge 2 ]] || usage 2
ROLE=$1; DISTRO=$2; shift 2
[[ "$ROLE" == hub || "$ROLE" == node ]] || die "the role is hub or node, not '$ROLE'"
case "$DISTRO" in debian-13|ubuntu-26.04|fedora-44) ;; *) die "the distribution is debian-13, ubuntu-26.04 or fedora-44, not '$DISTRO'" ;; esac

VMID=""; NAME=""; STORAGE=""; BRIDGE=vmbr0; CORES=2; MEM=""; DISK=""; IP=""; GW=""; DNS=""; CIUSER=dcs; SSHKEY=""; ASKPW=0
FW=bios; TEMPLATE=0; START=1; FILE=""; BASE="$RELEASE_URL"; DRY=0
while [[ $# -gt 0 ]]; do case "$1" in
    --vmid) VMID=$2; shift 2 ;; --name) NAME=$2; shift 2 ;; --storage) STORAGE=$2; shift 2 ;; --bridge) BRIDGE=$2; shift 2 ;;
    --cores) CORES=$2; shift 2 ;; --memory) MEM=$2; shift 2 ;; --disk) DISK=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;; --gateway) GW=$2; shift 2 ;; --dns) DNS=$2; shift 2 ;; --user) CIUSER=$2; shift 2 ;;
    --ssh-key) SSHKEY=$2; shift 2 ;; --password) ASKPW=1; shift ;; --firmware) FW=$2; shift 2 ;;
    --template) TEMPLATE=1; START=0; shift ;; --no-start) START=0; shift ;;
    --file) FILE=$2; shift 2 ;; --base-url) BASE=${2%/}; shift 2 ;; --dry-run) DRY=1; shift ;;
    -h|--help) usage 0 ;; *) die "unknown option: $1 (see --help)" ;;
esac; done
[[ "$FW" == bios || "$FW" == uefi ]] || die "--firmware is bios or uefi"
[[ "$ROLE" == hub ]] && { : "${MEM:=4096}" "${DISK:=32}"; } || { : "${MEM:=2048}" "${DISK:=16}"; }
[[ -n "$NAME" ]] || { [[ $ROLE == hub ]] && NAME=dcs-hub || NAME=dcs-node-$DISTRO; }
[[ "$NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,60}[A-Za-z0-9])?$ ]] || die "'$NAME' is not a valid VM name"
[[ "$CORES" =~ ^[0-9]+$ && "$MEM" =~ ^[0-9]+$ && "$DISK" =~ ^[0-9]+$ ]] || die "--cores, --memory and --disk are numbers"
[[ -z "$IP" || -n "$GW" ]] || die "--ip needs --gateway"
run() { if [[ $DRY == 1 ]]; then printf '   $ %s\n' "$*"; else "$@"; fi; }

# --- this must be a Proxmox host ---------------------------------------------------------------------------------
command -v qm >/dev/null && command -v pvesm >/dev/null && command -v pvesh >/dev/null || die "qm/pvesm/pvesh not found: run this on the Proxmox host"
[[ $EUID -eq 0 ]] || die "run it as root"
PVE=$(pveversion 2>/dev/null | sed -n 's|pve-manager/\([0-9.]*\).*|\1|p'); [[ "${PVE%%.*}" =~ ^[0-9]+$ && ${PVE%%.*} -ge 8 ]] || warn "Proxmox VE ${PVE:-?}: 8.2 or newer is expected (disk import)"

# --- storages ------------------------------------------------------------------------------------------------------------
if [[ -z "$STORAGE" ]]; then
    if pvesm status --content images 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx local-lvm; then STORAGE=local-lvm
    else STORAGE=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'); fi
fi
[[ -n "$STORAGE" ]] || die "no storage for VM disks: give one with --storage"
pvesm status --content images 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" || die "storage '$STORAGE' cannot hold VM disks"
# the image is imported from a storage that allows the 'import' content type (a directory storage; 'local' by default).
# (a Proxmox host has no jq: the few fields needed are cut out of the JSON with sed)
sfield() { pvesh get "/storage/$1" --output-format json 2>/dev/null | tr -d ' ' | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
ISTOR=""
for s in local $(pvesm status --content import 2>/dev/null | awk 'NR>1 {print $1}'); do
    [[ "$(sfield "$s" type)" == dir ]] && { ISTOR=$s; break; }
done
[[ -n "$ISTOR" ]] || die "no directory storage to import from (Datacenter → Storage → local → Content → tick 'Import')"
CONTENT=$(sfield "$ISTOR" content)
if [[ ",$CONTENT," != *,import,* ]]; then
    say "the storage '$ISTOR' gets the 'Import' content type"
    run pvesm set "$ISTOR" --content "${CONTENT:+$CONTENT,}import"
fi
IDIR=$(sfield "$ISTOR" path)/import
[[ -d "$IDIR" || $DRY == 1 ]] || mkdir -p "$IDIR"

# --- the image -------------------------------------------------------------------------------------------------------------
IMG="dcs-$ROLE-$DISTRO.qcow2"; DEST="$IDIR/$IMG"
if [[ -n "$FILE" ]]; then
    [[ -f "$FILE" ]] || die "no such file: $FILE"
    say "using $FILE"
    [[ $DRY == 1 ]] || cp -f "$FILE" "$DEST.part"
else
    say "downloading $IMG from $BASE"
    if [[ $DRY != 1 ]]; then
        curl -fL --retry 3 --progress-bar -o "$DEST.part" "$BASE/$IMG" || { rm -f "$DEST.part"; die "the download failed ($BASE/$IMG)"; }
        if SUMS=$(curl -fsSL "$BASE/SHA256SUMS" 2>/dev/null); then
            want=$(awk -v f="$IMG" '$2 == f || $2 == "*"f {print $1}' <<< "$SUMS")
            got=$(sha256sum "$DEST.part" | cut -d' ' -f1)
            [[ -z "$want" || "$want" == "$got" ]] || { rm -f "$DEST.part"; die "the checksum does not match ($got, expected $want): the download is damaged"; }
            [[ -n "$want" ]] && ok "checksum verified" || warn "$IMG is not in SHA256SUMS: not verified"
        else warn "no SHA256SUMS next to the image: not verified"; fi
    fi
fi
[[ $DRY == 1 ]] || mv -f "$DEST.part" "$DEST"

# --- the VM ---------------------------------------------------------------------------------------------------------------
[[ -n "$VMID" ]] || VMID=$(pvesh get /cluster/nextid)
[[ "$VMID" =~ ^[0-9]+$ ]] || die "VM id '$VMID'"
qm status "$VMID" >/dev/null 2>&1 && die "VM $VMID exists already (--vmid)"
TAGS="dcs;$ROLE"; [[ $TEMPLATE == 1 ]] && TAGS="dcs;template"
KEYFILE=""
if [[ -n "$SSHKEY" ]]; then [[ -f "$SSHKEY" ]] || die "no such key file: $SSHKEY"; KEYFILE=$SSHKEY
else cat /root/.ssh/*.pub > /tmp/dcs-proxmox-keys.$$ 2>/dev/null && KEYFILE=/tmp/dcs-proxmox-keys.$$ || true; fi
trap '[[ "${KEYFILE:-}" == /tmp/dcs-proxmox-keys.* ]] && rm -f "$KEYFILE"' EXIT
PW=""; if [[ $ASKPW == 1 ]]; then read -r -s -p "password for $CIUSER: " PW; echo; fi
[[ -n "$KEYFILE" || -n "$PW" ]] || warn "no ssh key and no password: you could not log in (--ssh-key FILE or --password)"

say "creating VM $VMID ($NAME): $CORES cores, $MEM MB, $DISK GB on $STORAGE, $FW, $([[ -n $IP ]] && echo "$IP" || echo DHCP)"
CREATE=(qm create "$VMID" --name "$NAME" --tags "$TAGS" --ostype l26 --memory "$MEM" --cores "$CORES" --cpu host
        --scsihw virtio-scsi-single --scsi0 "$STORAGE:0,import-from=$ISTOR:import/$IMG,discard=on,iothread=1,ssd=1" --boot order=scsi0
        --net0 "virtio,bridge=$BRIDGE" --serial0 socket --agent enabled=1 --onboot "$([[ $ROLE == hub && $TEMPLATE == 0 ]] && echo 1 || echo 0)"
        --ide2 "$STORAGE:cloudinit" --ciuser "$CIUSER" --ipconfig0 "$([[ -n $IP ]] && echo "ip=$IP,gw=$GW" || echo ip=dhcp)")
[[ $FW == uefi ]] && CREATE+=(--machine q35 --bios ovmf --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0")
[[ -n "$DNS" ]] && CREATE+=(--nameserver "$DNS")
[[ -n "$KEYFILE" ]] && CREATE+=(--sshkeys "$KEYFILE")
[[ -n "$PW" ]] && CREATE+=(--cipassword "$PW")
if [[ $DRY == 1 ]]; then printf '   $ %s\n' "${CREATE[*]}"; else "${CREATE[@]}" >/dev/null || { qm destroy "$VMID" --purge >/dev/null 2>&1 || true; die "qm create failed"; }; fi
run qm resize "$VMID" scsi0 "${DISK}G" >/dev/null
[[ $DRY == 1 ]] || qm set "$VMID" --description "DCS $ROLE image ($DISTRO), made by dcs-proxmox.sh on $(date +%F)" >/dev/null
if [[ $TEMPLATE == 1 ]]; then
    run qm template "$VMID" >/dev/null
    ok "template $VMID ($NAME) is ready: clone it from Proxmox, or let the hub use it"
    exit 0
fi
ok "VM $VMID ($NAME) created"
if [[ $START == 1 ]]; then
    run qm start "$VMID"
    ok "started"
    if [[ $ROLE == hub ]]; then
        cat <<MSG

   The hub sets itself up on its first start (a minute or two: it pulls the dashboard image).
   Then open   http://<the VM's address>:3000   in a browser and follow the wizard.
   The address is on the VM's console (Proxmox → $VMID → Console) and in Summary once the guest agent answers.
   Log in over ssh as '$CIUSER' with the key.
MSG
    fi
fi
